/// One terminal row in a preview snapshot.
public struct PreviewGridLine: Equatable, Sendable {
    /// Zero-based terminal row represented by this line.
    public let row: Int
    /// Explicitly positioned text runs ordered by terminal column.
    public let spans: [PreviewGridSpan]

    /// Creates one immutable preview row.
    public init(row: Int, spans: [PreviewGridSpan]) {
        self.row = row
        self.spans = spans
    }
}
