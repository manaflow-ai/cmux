/// One semantic terminal row retained by the mobile render-grid snapshot.
public struct MobileTerminalRenderGridSnapshotRow: Equatable, Sendable {
    /// Styled spans in the row.
    public var spans: [MobileTerminalRenderGridSnapshotCellSpan]

    /// Creates a semantic row from styled spans.
    public init(spans: [MobileTerminalRenderGridSnapshotCellSpan] = []) {
        self.spans = spans
    }

    /// Plain text reconstructed from the row's spans, padding gaps with spaces.
    public var plainText: String {
        var result = ""
        var width = 0
        for span in spans.sorted(by: { $0.column < $1.column }) {
            if width < span.column {
                result += String(repeating: " ", count: span.column - width)
                width = span.column
            }
            result += span.text
            width += max(span.cellWidth, span.text.count)
        }
        return result
    }
}
