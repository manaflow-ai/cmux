/// A fresh, user-presentable safety snapshot captured before worktree removal.
struct WorktreeSidebarDeletionInspection: Equatable, Sendable {
    enum BranchDisposition: Equatable, Sendable {
        case deleteMerged(String)
        case keepUnmerged(String)
        case noLocalBranch
    }

    let worktree: WorktreeSidebarWorktree
    let statusFingerprint: WorktreeSidebarGitFingerprint
    let ignoredFingerprint: WorktreeSidebarGitFingerprint
    let hasUncommittedChanges: Bool
    let hasIgnoredFiles: Bool
    let unpushedCommitCount: Int
    let branchDisposition: BranchDisposition
    let hasInitializedSubmodules: Bool

    var requiresForceRemoval: Bool {
        hasUncommittedChanges || hasInitializedSubmodules
    }
}

struct WorktreeSidebarDeletionStatusSnapshot {
    var statusFingerprint = WorktreeSidebarGitFingerprint.empty
    var ignoredFingerprint = WorktreeSidebarGitFingerprint.empty
    var hasUncommittedChanges = false
    var hasIgnoredFiles = false
}
