import Foundation

/// Workspaces to close only after Git has removed their worktree directory.
@MainActor
struct WorktreeSidebarWorkspaceClosePlan {
    struct Entry {
        let manager: TabManager
        let workspaceIDs: [UUID]
    }

    let entries: [Entry]
    let fallbackDirectory: String
}
