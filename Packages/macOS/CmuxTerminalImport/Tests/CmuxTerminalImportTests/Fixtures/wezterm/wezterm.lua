-- WezTerm config fixture
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

config.font = wezterm.font('Berkeley Mono', { weight = 'Medium' })
config.font_size = 15
config.color_scheme = 'Tokyo Night'
config.default_cursor_style = "BlinkingBar"
config.window_background_opacity = 0.8
config.macos_window_background_blur = 30
config.scrollback_lines = 20000
config.send_composed_key_when_left_alt_is_pressed = false
config.send_composed_key_when_right_alt_is_pressed = false
config.window_padding = {
  left = 10,
  right = '10px',
  top = "0.5cell",
  bottom = 5,
}
config.colors = {
  foreground = '#dcd7ba',
  background = "#1f1f28",
  cursor_bg = '#c8c093',
  cursor_fg = '#1f1f28',
  selection_bg = '#2d4f67',
  selection_fg = '#c8c093',
  ansi = { '#090618', '#c34043', '#76946a', '#c0a36e', '#7e9cd8', '#957fb8', '#6a9589', '#c8c093' },
  brights = { '#727169', '#e82424', '#98bb6c', '#e6c384', '#7fb4ca', '#938aa9', '#7aa89f', '#dcd7ba' },
}

--[[ A block comment with config.font_size = 99 inside ]]
config.line_height = 1.1
config.initial_cols = os.getenv("COLS") or 120

if wezterm.target_triple == 'aarch64-apple-darwin' then
  config.font_size = 17
end

wezterm.on('update-status', function(window)
  config.window_background_opacity = 0.5
end)

return config
