/// One cursor-paged file-diff response.
public struct DiffFilePage: Sendable, Codable, Equatable {
    /// Parsed hunks included in this page.
    public let hunks: [DiffHunk]
    /// Whether the file is binary and therefore has no textual hunks.
    public let isBinary: Bool
    /// Whether a large textual diff is gated until the caller passes `force`.
    public let tooLarge: Bool
    /// The opaque row offset for the next page, or `nil` at the end.
    public let nextCursor: Int?

    /// Creates a file-diff page.
    /// - Parameters:
    ///   - hunks: Parsed hunks included in the page.
    ///   - isBinary: Whether the file is binary.
    ///   - tooLarge: Whether a large diff remains gated.
    ///   - nextCursor: The next row offset, or `nil` at the end.
    public init(hunks: [DiffHunk], isBinary: Bool, tooLarge: Bool, nextCursor: Int?) {
        self.hunks = hunks
        self.isBinary = isBinary
        self.tooLarge = tooLarge
        self.nextCursor = nextCursor
    }
}
