/// Aggregate counts for a diff summary.
public struct DiffTotals: Sendable, Codable, Equatable {
    /// The number of changed files.
    public let files: Int
    /// The total added lines across non-binary files.
    public let additions: Int
    /// The total deleted lines across non-binary files.
    public let deletions: Int

    /// Creates aggregate diff counts.
    /// - Parameters:
    ///   - files: The number of changed files.
    ///   - additions: The total number of added lines.
    ///   - deletions: The total number of deleted lines.
    public init(files: Int, additions: Int, deletions: Int) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }
}
