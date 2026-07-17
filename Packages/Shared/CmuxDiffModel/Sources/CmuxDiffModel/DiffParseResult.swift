/// The parsed representation of one unified-diff response.
public struct DiffParseResult: Sendable, Equatable {
    /// Parsed hunks in display order.
    public let hunks: [DiffHunk]
    /// Meaningful Git metadata retained when a change has no text hunks.
    public let metadataLines: [String]
    /// Whether the source diff text was capped by the transport producer.
    public let isTruncated: Bool

    /// Creates a parsed diff result.
    ///
    /// - Parameters:
    ///   - hunks: Parsed hunks in display order.
    ///   - metadataLines: Meaningful non-hunk Git metadata in display order.
    ///   - isTruncated: Whether the source diff text was capped.
    public init(hunks: [DiffHunk], metadataLines: [String] = [], isTruncated: Bool) {
        self.hunks = hunks
        self.metadataLines = metadataLines
        self.isTruncated = isTruncated
    }
}
