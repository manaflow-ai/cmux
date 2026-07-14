/// Contains one cursor-paged file diff suitable for a single wire response.
public struct FileDiff: Sendable, Equatable {
    /// The hunks represented in this response page.
    public let hunks: [DiffHunk]
    /// Whether the file is binary and therefore has no text hunks.
    public let isBinary: Bool
    /// Whether the complete patch crosses the engine's large-diff threshold.
    public let tooLarge: Bool
    /// The opaque cursor for the next row page, or `nil` at the end.
    public let nextCursor: String?

    /// Creates a paged file diff.
    /// - Parameters:
    ///   - hunks: The hunks represented in the page.
    ///   - isBinary: Whether the file is binary.
    ///   - tooLarge: Whether the complete patch is large.
    ///   - nextCursor: The cursor for the next page.
    public init(hunks: [DiffHunk], isBinary: Bool, tooLarge: Bool, nextCursor: String?) {
        self.hunks = hunks
        self.isBinary = isBinary
        self.tooLarge = tooLarge
        self.nextCursor = nextCursor
    }
}
