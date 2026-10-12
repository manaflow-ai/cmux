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

    /// Selects a local workspace from a Cloud tree row in the window that owns it.
    ///
    /// Every window's Cloud tree reads the app-wide surface catalog, so a row
    /// can point at a workspace that another window owns. Selecting it on the
    /// panel's own manager would do nothing, so route to the owner and bring
    /// that window forward (#19967).
    /// - Parameters:
    ///   - workspaceID: The local workspace the row resolved to.
    ///   - panelManager: The manager of the window whose Cloud tree was used.
    /// - Returns: Whether a live owner selected the workspace.
    @discardableResult
    func selectCloudTreeLocalWorkspace(_ workspaceID: UUID, from panelManager: TabManager?) -> Bool {
        let owner = tabManagerFor(tabId: workspaceID)
            ?? panelManager.flatMap { $0.workspacesById[workspaceID] != nil ? $0 : nil }
        guard let owner else { return false }
        if owner !== panelManager, let windowId = owner.windowId {
            _ = focusMainWindow(windowId: windowId)
        }
        owner.selectedTabId = workspaceID
        return true
    }
}
