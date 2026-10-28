/// The default colors the app paints a daemon's terminals with.
///
/// The cmux-tui daemon answers terminal color queries (OSC 10, 11 and 12)
/// for the terminals it owns; the app's Ghostty surfaces only mirror them.
/// Programs such as Codex read the background that way to tint their own
/// rows, so the daemon must answer with these colors, not its own read of
/// the Ghostty config files. Each color is `#rrggbb`.
public struct TerminalDefaultColors: Sendable, Hashable {
    /// The default foreground (OSC 10).
    public var foreground: String
    /// The default background (OSC 11).
    public var background: String
    /// The cursor color (OSC 12); nil when the theme names none.
    public var cursor: String?

    /// - Parameters:
    ///   - foreground: The default foreground, `#rrggbb`.
    ///   - background: The default background, `#rrggbb`.
    ///   - cursor: The cursor color, `#rrggbb`, or nil when the theme names none.
    public init(foreground: String, background: String, cursor: String? = nil) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
    }
}
