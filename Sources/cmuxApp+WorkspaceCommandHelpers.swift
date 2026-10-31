import CMUXAgentLaunch
import Foundation

extension cmuxApp {
    /// Resolves a workspace's current sidebar position for command enablement.
    func selectedWorkspaceIndex(in manager: TabManager, workspaceId: UUID) -> Int? {
        manager.tabs.firstIndex { $0.id == workspaceId }
    }

    // Workspace menu move commands for the selected workspace.
    func moveSelectedWorkspaceToTop(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        manager.moveTabsToTop([workspace.id])
        manager.selectWorkspace(workspace)
    }

    func moveSelectedWorkspaceToBottom(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        manager.moveTabsToBottom([workspace.id])
        manager.selectWorkspace(workspace)
    }

    func moveSelectedWorkspace(in manager: TabManager, toWindow windowId: UUID) {
        guard let workspace = manager.selectedWorkspace else { return }
        _ = AppDelegate.shared?.moveWorkspaceToWindow(workspaceId: workspace.id, windowId: windowId, focus: true)
    }

    func moveSelectedWorkspaceToNewWindow(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        _ = AppDelegate.shared?.moveWorkspaceToNewWindow(workspaceId: workspace.id, focus: true)
    }
}


extension cmuxApp {
    /// Every terminal inherits the app environment. When cmux is launched from
    /// inside a cmux Claude session, NODE_OPTIONS carries that session's restore
    /// preload, and `node` fails in every shell once the file is gone (#22274).
    static func removeInheritedClaudeNodeOptionsPreload() {
        let updates = AgentLaunchEnvironmentPolicy().inheritedNodeOptionsRepair(
            from: ProcessInfo.processInfo.environment
        )
        for (key, value) in updates {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }

}
