extension TerminalTheme {
    /// A Ghostty color resolved from the cell beneath a cursor or selection.
    public enum CellRelativeColor: String, Codable, Equatable, Sendable {
        /// Use the rendered cell foreground.
        case foreground = "cell-foreground"
        /// Use the rendered cell background.
        case background = "cell-background"
    }
}
