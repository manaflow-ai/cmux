import Foundation

/// The shared setup route stays inside the caller's selected workspace.
@MainActor
struct CloudVPNSetupNavigation {
    let coordinator: CloudTunnelCoordinator?

    @discardableResult
    func open(in manager: TabManager, focus: Bool = true) -> Workspace? {
        if let workspace = manager.selectedWorkspace,
           let paneID = workspace.bonsplitController.focusedPaneId {
            guard workspace.openOrFocusCloudVPNSetupSurface(inPane: paneID, coordinator: coordinator, focus: focus) != nil else { return nil }
            return workspace
        }
        guard let workspace = manager.addWorkspaceIfActive(
            title: String(localized: "cloud.vpn.setup.title", defaultValue: "Cloud VPN"),
            select: focus,
            eagerLoadTerminal: false,
            autoWelcomeIfNeeded: false,
            autoRefreshMetadata: false,
            allowTextBoxFocusDefault: false
        ) else { return nil }
        guard let initialPanelID = workspace.focusedPanelId,
        let paneID = workspace.paneId(forPanelId: initialPanelID),
        workspace.newCloudVPNSetupSurface(inPane: paneID, coordinator: coordinator, focus: focus) != nil else {
            manager.closeWorkspace(workspace, recordHistory: false)
            return nil
        }
        _ = workspace.closePanel(initialPanelID, force: true)
        return workspace
    }
}
