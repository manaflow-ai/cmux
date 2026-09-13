import Foundation

/// The existing dedicated guide flow keeps Cloud workspaces free of local utility panes.
@MainActor
struct CloudVPNSetupNavigation {
    let coordinator: CloudTunnelCoordinator?

    @discardableResult
    func open(in manager: TabManager, focus: Bool = true) -> Workspace? {
        if let workspace = manager.tabs.first(where: { $0.panels.values.contains { $0 is CloudVPNSetupPanel } }),
           let panel = workspace.panels.values.first(where: { $0 is CloudVPNSetupPanel }) {
            if focus {
                manager.selectedTabId = workspace.id
                workspace.focusPanel(panel.id)
            }
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
