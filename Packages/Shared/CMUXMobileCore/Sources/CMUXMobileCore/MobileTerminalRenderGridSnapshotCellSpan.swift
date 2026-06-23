/// A styled run of terminal cells in a semantic render-grid snapshot row.
public struct MobileTerminalRenderGridSnapshotCellSpan: Equatable, Sendable {
    /// Zero-based grid column where the span begins.
    public var column: Int
    /// Number of terminal cells occupied by the span.
    public var cellWidth: Int
    /// Text content for the span.
    public var text: String
    /// Resolved visual style for the span.
    public var style: MobileTerminalRenderGridFrame.Style

    /// Creates a styled semantic row span.
    public init(
        column: Int,
        cellWidth: Int,
        text: String,
        style: MobileTerminalRenderGridFrame.Style
    ) {
        self.column = column
        self.cellWidth = cellWidth
        self.text = text
        self.style = style
    }
}
