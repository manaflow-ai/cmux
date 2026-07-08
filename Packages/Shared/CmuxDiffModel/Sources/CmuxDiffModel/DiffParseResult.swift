/// The parsed representation of one unified-diff response.
public struct DiffParseResult: Sendable, Equatable {
    /// Parsed hunks in display order.
    public let hunks: [DiffHunk]
    /// Whether the source diff text was capped by the transport producer.
    public let isTruncated: Bool

    /// Creates a parsed diff result.
    ///
    /// - Parameters:
    ///   - hunks: Parsed hunks in display order.
    ///   - isTruncated: Whether the source diff text was capped.
    public init(hunks: [DiffHunk], isTruncated: Bool) {
        self.hunks = hunks
        self.isTruncated = isTruncated
    }
}
