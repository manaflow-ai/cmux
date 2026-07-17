extension MobileTerminalRenderGridFrame {
    enum CodingKeys: String, CodingKey {
        case format
        case surfaceID = "surface_id"
        case stateSeq = "state_seq"
        case columns
        case rows
        case cursor
        case full
        case clearedRows = "cleared_rows"
        case styles
        case rowSpans = "row_spans"
        case activeScreen = "active_screen"
        case modes
        case terminalForeground = "terminal_foreground"
        case terminalBackground = "terminal_background"
        case terminalCursorColor = "terminal_cursor_color"
        case terminalTheme = "terminal_theme"
        case terminalConfigTheme = "terminal_config_theme"
        case terminalThemeRevision = "terminal_theme_revision"
        case scrollbackRows = "scrollback_rows"
        case scrollbackSpans = "scrollback_spans"
    }
}
