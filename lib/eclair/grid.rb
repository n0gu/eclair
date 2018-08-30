# frozen_string_literal: true
require "eclair/group_item"
require "eclair/color"

module Eclair
  class Grid
    attr_reader :mode

    def initialize keyword = ""
      case config.provider
      when :ec2
        require "eclair/providers/ec2"
        @provider = EC2Provider
      when :k8s
        require "eclair/providers/k8s"
        @provider = K8sProvider
      end
      @item_class = @provider.item_class

      @grid = config.columns.times.map{[]}
      @scroll = config.columns.times.map{0}
      @header_rows = 4
      @cursor = [0,0]
      @cell_width = Curses.stdscr.maxx/config.columns
      @maxy = Curses.stdscr.maxy - @header_rows
      @mode = :nav

      @search_buffer = ""
      @search_matched = []

      @provider.prepare keyword
      assign
      at(*@cursor).toggle_select
      draw_all
    end

    def move key
      x,y = @cursor
      mx,my = {
        Curses::KEY_UP => [0,-1],
        Curses::KEY_DOWN => [0,1],
        Curses::KEY_LEFT => [-1,0],
        Curses::KEY_RIGHT => [1,0],
      }[key]

      newx = x
      loop do
        newx = (newx + mx) % @grid.length
        break if @grid[newx].length > 0
      end
      newy = (y + my - @scroll[x] + @scroll[newx])
      if my != 0
        newy %= @grid[newx].length
      end
      if newy >= @grid[newx].length
        newy = @grid[newx].length-1
      end

      move_cursor(newx, newy)
    end

    def space
      if @mode == :nav
        @mode = :sel
        at(*@cursor).toggle_select
      end
      at(*@cursor).toggle_select
      if @mode == :sel && @provider.items.all?{|i| !i.selected}
        @mode = :nav
        at(*@cursor).toggle_select
      end
      draw(*@cursor)
    end

    def action
      targets = @provider.items.select{|i| i.selected && i.connectable?}
      return if targets.length == 0

      Curses.close_screen

      if targets.length == 1
        cmd = targets.first.command
      else
        cmds = []
        target_cmd = ""

        targets.each_with_index do |target, i|
          if i == 0
            if ENV['TMUX'] # Eclair called inside of tmux
              # Create new session and save window id
              window_name = `tmux new-window -P -- '#{target.command}'`.strip
              target_cmd = "-t #{window_name}"
            else # Eclair called from outside of tmux
              # Create new session and save session
              session_name = "eclair#{Time.now.to_i}"
              target_cmd = "-t #{session_name}"
              `tmux new-session -d -s #{session_name} -- '#{target.command}'`
            end
          else # Split layout and
            cmds << "split-window #{target_cmd} -- '#{target.command}'"
            cmds << "select-layout #{target_cmd} tiled"
          end
        end
        cmds << "set-window-option #{target_cmd} synchronize-panes on"
        cmds << "attach #{target_cmd}" unless ENV['TMUX']
        cmd = "tmux #{cmds.join(" \\; ")}"
      end
      system(cmd)
      exit()
      resize
    end

    def resize
      Curses.clear
      @scroll.fill(0)
      @cell_width = Curses.stdscr.maxx/config.columns
      @maxy = Curses.stdscr.maxy - @header_rows
      rescroll(*@cursor)
      draw_all
    end

    def start_search
      @mode_prev = @mode
      @mode = :search
    end

    def end_search
      @mode = @mode_prev
      move_next_search
    end

    def move_next_search
      return if @search_matched.empty?
      move_cursor(*@search_matched.bsearch { |pos| (pos <=> @cursor) == 1 } || @search_matched[0])
    end

    def move_prev_search
      return if @search_matched.empty?
      next_idx = @search_matched.bsearch_index { |pos| (pos <=> @cursor) != -1 } || 0
      move_cursor(*@search_matched[next_idx - 1])
    end

    def append_search key
      return if key == nil
      if key == 127 # backspace
        @search_buffer = @search_buffer[0...-1]
      else
        begin
          @search_buffer = @search_buffer + key.to_s
        rescue; end
      end
      update_search
    end

    def clear_search
      @search_buffer = ""
      update_search
    end

    private

    def move_cursor x, y
      prev = @cursor.dup
      @cursor = [x, y]

      prev_item = at(*prev)
      curr_item = at(*@cursor)
      rescroll(*@cursor)
      if @mode == :nav
        prev_item.toggle_select
        curr_item.toggle_select
      end
      draw(*prev)
      draw(*@cursor)
      update_header(curr_item.header)
    end


    def update_header str, pos = 0
      str.split("\n").map(&:strip).each_with_index do |line, i|
        Curses.setpos(i + pos,0)
        Curses.clrtoeol
        Curses.addstr(line)
      end
    end

    def update_search
      old_matched = Set.new(@search_matched)
      @search_matched = []

      if not @search_buffer.empty?
        @grid.each_with_index do |column, x|
          column.each_with_index do |_, y|
            if not at(x, y).is_a?(GroupItem) and at(x, y).search_key.include?(@search_buffer)
              @search_matched << [x, y]
            end
          end
        end
      end

      (old_matched | Set.new(@search_matched)).each do |x, y|
        draw_item(x, y)
      end

      Curses.setpos(@header_rows - 1, 0)
      Curses.clrtoeol
      if @mode != :search && @search_buffer.empty?
        Curses.addstr('/: Start search, n: go to next search, N: go to previous search')
      else
        Curses.addstr('/' + @search_buffer)
      end

    end

    def rescroll x, y
      unless (@scroll[x]...@maxy+@scroll[x]).include? y
        if y < @scroll[x]
          @scroll[x] = y
        elsif y >= @maxy
          @scroll[x] = y - @maxy + 1
        end
        (@scroll[x]...@maxy+@scroll[x]).each do |ty|
          draw_item(x, ty)
        end
      end
    end

    def at x, y
      @grid[x][y]
    end

    def make_label target
      ind = (@mode != :nav && target.selected) ? "*" : " "
      label = "#{target.label} #{ind}"
      label.slice(0, @cell_width).ljust(@cell_width)
    end

    def draw_all
      @grid.each_with_index do |column, x|
        column.each_with_index do |_, y|
          draw_item(x,y)
        end
      end
      update_header(at(*@cursor).header)
      update_search
    end

    def color x, y
      if @cursor == [x,y]
        Color.fetch(Curses::COLOR_BLACK, Curses::COLOR_CYAN)
      elsif @search_matched.include? [x,y]
        Color.fetch(Curses::COLOR_BLACK, Curses::COLOR_YELLOW)
      else
        Color.fetch(*@grid[x][y].color)
      end
    end

    def draw_item x, y
      target = @grid[x][y]

      drawy = y - @scroll[x]
      if drawy < 0 || drawy + @header_rows >= Curses.stdscr.maxy
        return
      end
      cell_color = color(x,y)
      Curses.setpos(drawy + @header_rows, x * @cell_width)
      Curses.attron(cell_color) do
        Curses.addstr make_label(target)
      end
      Curses.refresh
    end

    def draw x, y
      target = @grid[x][y]
      draw_item(x, y)
      if target.is_a?(GroupItem)
        (y+1).upto(y+target.length).each do |ny|
          draw_item(x, ny)
        end
      end
    end

    def assign
      @groups = @provider.items.group_by(&config.group_by)
      @groups.each do |name, items|
        group_name = "#{name} (#{items.length})"
        target = @grid.min_by(&:length)
        target << @provider.group_class.new(group_name, items)
        items.sort_by(&:label).each do |item|
          target << item
        end
      end
    end

    def config
      Eclair.config
    end
  end
end
