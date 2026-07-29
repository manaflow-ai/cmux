/// The location-based identity of a Git worktree.
///
/// The tuple deliberately excludes branch and HEAD because Git may change both
/// behind cmux's back. Enrichment should be keyed by this value and discarded
/// when a fresh Git listing no longer contains it.
public struct WorktreeIdentity: Hashable, Codable, Sendable {
    /// The host on which the repository lives.
    public let host: WorktreeHostID

    /// The stable main-repository path reported by Git's first worktree entry.
    public let repoPath: String

    /// The worktree's host-local absolute path.
    public let worktreePath: String

    /// Creates a worktree identity.
    /// - Parameters:
    ///   - host: The execution host identifier.
    ///   - repoPath: The stable main-repository path.
    ///   - worktreePath: The linked or main worktree path.
    public init(host: WorktreeHostID, repoPath: String, worktreePath: String) {
        self.host = host
        self.repoPath = repoPath
        self.worktreePath = worktreePath
    }
}
