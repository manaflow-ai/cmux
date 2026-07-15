/// The decoded result of `mobile.workspace.diffs.file`.
public struct MobileDiffFileResponse: Codable, Sendable, Equatable {
    /// Unified-diff hunks included in this cursor page.
    public let hunks: [MobileDiffHunk]
    /// Whether the file contains binary content.
    public let isBinary: Bool
    /// Whether a large textual diff remains gated behind `force`.
    public let tooLarge: Bool
    /// The next opaque row cursor, or `nil` at the end.
    public let nextCursor: Int?

    /// Creates a cursor-paged file-diff response.
    /// - Parameters:
    ///   - hunks: Unified-diff hunks in this page.
    ///   - isBinary: Whether the file contains binary content.
    ///   - tooLarge: Whether a large textual diff remains gated.
    ///   - nextCursor: The next row cursor, or `nil` at the end.
    public init(
        hunks: [MobileDiffHunk],
        isBinary: Bool,
        tooLarge: Bool,
        nextCursor: Int? = nil
    ) {
        self.hunks = hunks
        self.isBinary = isBinary
        self.tooLarge = tooLarge
        self.nextCursor = nextCursor
    }
}
