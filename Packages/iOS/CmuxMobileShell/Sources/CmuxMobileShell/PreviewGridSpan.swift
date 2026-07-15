/// One explicitly positioned styled text run in a preview grid row.
public struct PreviewGridSpan: Equatable, Sendable {
    /// Zero-based terminal column at which this run begins.
    public let column: Int
    /// Number of terminal cells occupied by the run, including wide glyphs.
    public let cellWidth: Int
    /// Printable text in the run.
    public let text: String
    /// Lightweight style applied to the run.
    public let style: PreviewGridStyle

    /// Creates one explicitly positioned preview text run.
    public init(column: Int, cellWidth: Int, text: String, style: PreviewGridStyle) {
        self.column = column
        self.cellWidth = cellWidth
        self.text = text
        self.style = style
    }
}
