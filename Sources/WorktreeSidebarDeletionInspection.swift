/// A fresh, user-presentable safety snapshot captured before worktree removal.
struct WorktreeSidebarDeletionInspection: Equatable, Sendable {
    enum BranchDisposition: Equatable, Sendable {
        case deleteMerged(String)
        case keepUnmerged(String)
        case noLocalBranch
    }

    let worktree: WorktreeSidebarWorktree
    let statusPorcelain: String
    let unpushedCommitCount: Int
    let branchDisposition: BranchDisposition
    let hasInitializedSubmodules: Bool

    var hasUncommittedChanges: Bool {
        !statusPorcelain.isEmpty
    }

    var requiresForceRemoval: Bool {
        hasUncommittedChanges || hasInitializedSubmodules
    }
}
