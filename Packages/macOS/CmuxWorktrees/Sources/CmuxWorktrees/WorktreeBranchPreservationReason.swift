/// The classified reason a branch survived worktree removal.
public enum WorktreeBranchPreservationReason: Equatable, Codable, Sendable {
    /// The caller explicitly requested that the branch remain.
    case requestedByCaller
    /// `git branch -d` refused deletion, optionally with Git's diagnostic.
    case deleteIfMergedRefused(message: String?)
    /// Compare-and-swap deletion refused because the branch moved, optionally with Git's diagnostic.
    case compareAndSwapRefused(message: String?)
}
