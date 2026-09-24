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
}
