import Foundation

/// Identifies the workspaces one tab manager should close after removal.
@MainActor
struct WorktreeSidebarWorkspaceClosePlanEntry {
    let manager: TabManager
    let workspaceIDs: [UUID]
}
