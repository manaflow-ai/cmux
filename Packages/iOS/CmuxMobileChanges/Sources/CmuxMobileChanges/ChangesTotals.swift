/// Aggregate file and line counts for a workspace changes snapshot.
public struct ChangesTotals: Sendable, Equatable {
    /// Number of changed files.
    public let filesChanged: Int
    /// Number of added lines.
    public let additions: Int
    /// Number of deleted lines.
    public let deletions: Int

    /// Creates aggregate change totals.
    /// - Parameters:
    ///   - filesChanged: Number of changed files.
    ///   - additions: Number of added lines.
    ///   - deletions: Number of deleted lines.
    public init(filesChanged: Int, additions: Int, deletions: Int) {
        self.filesChanged = filesChanged
        self.additions = additions
        self.deletions = deletions
    }
}

/// Compatibility name for aggregate totals used by the locked feature spec.
public typealias WorkspaceChangesTotals = ChangesTotals
