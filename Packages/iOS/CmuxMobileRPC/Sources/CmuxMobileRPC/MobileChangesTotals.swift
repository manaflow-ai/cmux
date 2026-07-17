/// Aggregates the file and line counts in a changes summary.
public struct MobileChangesTotals: Codable, Sendable, Equatable {
    /// The number of changed files represented by the summary.
    public let files: Int
    /// The total number of added lines.
    public let additions: Int
    /// The total number of deleted lines.
    public let deletions: Int

    /// Creates aggregate changes counts.
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
