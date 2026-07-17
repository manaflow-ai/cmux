/// A supported comparison baseline for working-tree diffs.
public enum DiffBaseKind: String, Sendable, Codable, Equatable {
    /// Compares the worktree with `HEAD`, or the empty tree before the first commit.
    case workingTree
    /// Compares the worktree with the commit captured at the start of the latest agent turn.
    case lastTurn
    /// Compares the worktree with the merge base of `HEAD` and the default branch.
    case branchBase
}
