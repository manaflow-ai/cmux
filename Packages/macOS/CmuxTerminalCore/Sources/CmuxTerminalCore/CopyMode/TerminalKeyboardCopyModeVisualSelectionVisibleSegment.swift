/// A characterwise selection segment expressed in viewport coordinates.
public struct TerminalKeyboardCopyModeVisualSelectionVisibleSegment: Equatable, Sendable {
    /// The segment's zero-based viewport row.
    public let viewportRow: Int
    /// The first selected terminal column.
    public let startColumn: Int
    /// The last selected terminal column.
    public let endColumn: Int

    /// Creates a visible, inclusive terminal-cell segment.
    public init(viewportRow: Int, startColumn: Int, endColumn: Int) {
        self.viewportRow = viewportRow
        self.startColumn = startColumn
        self.endColumn = endColumn
    }
}
