/// The colors a terminal profile defines: the 16 ANSI colors plus the special colors.
///
/// Every field is optional because sources often set only some of them; the
/// Ghostty theme written from a scheme contains only the colors that are set.
public struct TerminalColorScheme: Equatable, Sendable {
    /// ANSI palette entries keyed by index, 0 through 15.
    public var palette: [Int: TerminalColor] = [:]
    /// Default text color.
    public var foreground: TerminalColor?
    /// Default background color.
    public var background: TerminalColor?
    /// Cursor fill color.
    public var cursor: TerminalColor?
    /// Color of the text under a block cursor.
    public var cursorText: TerminalColor?
    /// Selection highlight color.
    public var selectionBackground: TerminalColor?
    /// Text color inside a selection.
    public var selectionForeground: TerminalColor?

    /// Creates an empty scheme.
    public init() {}

    /// Whether the scheme sets no colors at all.
    public var isEmpty: Bool {
        palette.isEmpty && foreground == nil && background == nil && cursor == nil
            && cursorText == nil && selectionBackground == nil && selectionForeground == nil
    }
}
