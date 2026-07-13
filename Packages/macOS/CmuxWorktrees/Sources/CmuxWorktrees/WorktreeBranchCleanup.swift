/// Branch cleanup requested after Git removes a worktree.
public enum WorktreeBranchCleanup: Sendable {
    /// Preserve the branch without attempting deletion.
    case keep
    /// Ask Git to delete only if the branch is merged (`git branch -d`).
    case deleteIfMerged
    /// Delete only if the ref still has the caller-proved object ID.
    case forceDelete(expectedOID: String)
}
