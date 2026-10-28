import CMUXAgentLaunch
import Darwin
import Foundation

extension cmuxApp {
    /// Removes a stale Claude restore preload before terminals inherit it.
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

    func moveSelectedWorkspace(in manager: TabManager, toWindow windowId: UUID) {
        guard let workspace = manager.selectedWorkspace else { return }
        _ = AppDelegate.shared?.moveWorkspaceToWindow(workspaceId: workspace.id, windowId: windowId, focus: true)
    }

    func moveSelectedWorkspaceToNewWindow(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        _ = AppDelegate.shared?.moveWorkspaceToNewWindow(workspaceId: workspace.id, focus: true)
    }
}
