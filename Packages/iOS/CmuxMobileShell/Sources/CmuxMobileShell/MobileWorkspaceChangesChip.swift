/// Immutable workspace-list chip counts published by ``MobileShellComposite``.
public struct MobileWorkspaceChangesChip: Sendable, Equatable {
    /// Number of changed files.
    public let filesChanged: Int
    /// Number of added lines.
    public let additions: Int
    /// Number of deleted lines.
    public let deletions: Int

    /// Creates a workspace changes chip snapshot.
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
