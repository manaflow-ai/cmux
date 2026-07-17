/// A fresh, user-presentable safety snapshot captured before worktree removal.
struct WorktreeSidebarDeletionInspection: Equatable, Sendable {
    typealias BranchDisposition = WorktreeSidebarDeletionBranchDisposition

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
