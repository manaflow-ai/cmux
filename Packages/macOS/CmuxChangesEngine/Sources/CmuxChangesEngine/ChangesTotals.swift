/// Aggregates file and line counts for a repository changes summary.
public struct ChangesTotals: Sendable, Equatable {
    /// The total number of changed files, including files omitted from a truncated response.
    public let files: Int
    /// The total number of added lines across text files.
    public let additions: Int
    /// The total number of deleted lines across text files.
    public let deletions: Int

    /// Creates aggregate changes totals.
    /// - Parameters:
    ///   - files: The changed-file count.
    ///   - additions: The added-line count.
    ///   - deletions: The deleted-line count.
    public init(files: Int, additions: Int, deletions: Int) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }
}
