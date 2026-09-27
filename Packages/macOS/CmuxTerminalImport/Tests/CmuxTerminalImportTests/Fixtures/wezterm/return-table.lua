local wezterm = require("wezterm")
return {
  font = wezterm.font_with_fallback({ "Fira Code", "Symbols Nerd Font" }),
  font_size = 12.5,
  default_cursor_style = "SteadyUnderline",
}
