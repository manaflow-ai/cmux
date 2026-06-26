import Foundation

/// Runs cwd-driven context-menu items from a sidebar group header.
@MainActor
enum SidebarWorkspaceGroupContextMenuRunner {
    static func run(
        item: CmuxResolvedConfigMenuAction,
        tabManager: TabManager,
        groupId: UUID
    ) {
        guard let appDelegate = AppDelegate.shared else { return }
        _ = appDelegate.runWorkspaceGroupConfiguredAction(
            item.action,
            tabManager: tabManager,
            groupId: groupId
        )
    }
}
