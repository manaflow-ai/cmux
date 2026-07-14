/// One terminal row in a preview snapshot.
public struct PreviewGridLine: Equatable, Sendable {
    /// Zero-based terminal row represented by this line.
    public let row: Int
    /// Explicitly positioned text runs ordered by terminal column.
    public let spans: [PreviewGridSpan]
}
