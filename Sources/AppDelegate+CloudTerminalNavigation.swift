import CmuxCloud
import Foundation

extension AppDelegate {
    /// Keeps focus and workspace teardown with the live app owner at effect time.
    static func makeCloudTerminalNavigationHost() -> CloudTerminalNavigationHost {
        CloudTerminalNavigationHost(
            focus: { panelID, workspaceID in SurfacePaneFactory.focus(panelID: panelID, in: workspaceID) },
            closeWorkspace: { workspaceID in
                guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
                      let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else { return }
                _ = manager.closeWorkspaceNonInteractively(workspace, recordHistory: false, allowPinned: true)
            }
        )
    }

    /// Selects a local workspace from a Cloud tree row.
    /// - Parameters:
    ///   - workspaceID: The local workspace the row resolved to.
    ///   - panelManager: The manager of the window whose Cloud tree was used.
    /// - Returns: Whether a manager selected the workspace.
    @discardableResult
    func selectCloudTreeLocalWorkspace(_ workspaceID: UUID, from panelManager: TabManager?) -> Bool {
        guard let panelManager, panelManager.workspacesById[workspaceID] != nil else { return false }
        panelManager.selectedTabId = workspaceID
        return true
    }
}
