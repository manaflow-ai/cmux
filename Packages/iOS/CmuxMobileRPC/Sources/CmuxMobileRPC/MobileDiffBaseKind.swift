/// A comparison baseline accepted by the workspace-diffs RPCs.
public enum MobileDiffBaseKind: String, Codable, Sendable, Equatable {
    /// Compares the worktree with `HEAD`.
    case workingTree
    /// Compares the worktree with the latest agent-turn baseline.
    case lastTurn
    /// Compares the worktree with the default branch's merge base.
    case branchBase
}
