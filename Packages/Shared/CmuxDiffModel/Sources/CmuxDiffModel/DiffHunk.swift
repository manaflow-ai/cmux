/// One `@@ ... @@` section parsed from a unified diff.
public struct DiffHunk: Sendable, Equatable, Identifiable {
    /// Stable hunk identity within a parsed result.
    public let id: Int
    /// The raw `@@` hunk header line.
    public let header: String
    /// First line in the old file.
    public let oldStart: Int
    /// Number of old-file lines covered by the hunk.
    public let oldCount: Int
    /// First line in the new file.
    public let newStart: Int
    /// Number of new-file lines covered by the hunk.
    public let newCount: Int
    /// Parsed lines in display order.
    public let lines: [DiffLine]

    /// Creates a parsed diff hunk.
    ///
    /// - Parameters:
    ///   - id: Stable hunk identity within a parsed result.
    ///   - header: The raw `@@` hunk header line.
    ///   - oldStart: First line in the old file.
    ///   - oldCount: Number of old-file lines covered by the hunk.
    ///   - newStart: First line in the new file.
    ///   - newCount: Number of new-file lines covered by the hunk.
    ///   - lines: Parsed lines in display order.
    public init(
        id: Int,
        header: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [DiffLine]
    ) {
        self.id = id
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}
