/// Selects the baseline used by a mobile workspace-changes request.
public enum MobileChangesBaseKind: String, Codable, Sendable, Equatable {
    /// Compares the working tree with `HEAD`, including staged, unstaged, and untracked files.
    case workingTree = "working_tree"
    /// Compares the working tree with the current agent session's last-turn baseline.
    case lastTurn = "last_turn"
    /// Compares the working tree with the merge base of `HEAD` and a branch.
    case branchBase = "branch_base"
}
