import Foundation

/// Workspaces to close only after Git has removed their worktree directory.
@MainActor
struct WorktreeSidebarWorkspaceClosePlan {
    typealias Entry = WorktreeSidebarWorkspaceClosePlanEntry

    let entries: [Entry]
    let fallbackDirectory: String
}
