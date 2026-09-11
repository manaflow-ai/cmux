import AppKit
import CmuxSettings

extension AppDelegate {
    /// Opens the optional Cloud VPN guide as a normal cmux pane.
    ///
    /// The command palette and explicit machine or port actions use this method
    /// so the setup flow has one behavior everywhere.
    @discardableResult
    func openCloudVPNSetupWorkspace(
        preferredTabManager: TabManager? = nil,
        preferredWindow: NSWindow? = nil,
        focus: Bool = true
    ) -> Workspace? {
        guard !ManagedDevicePolicy().isEnforced(.disableCloud) else { return nil }
        guard let manager = preferredTabManager
            ?? synchronizeActiveMainWindowContext(preferredWindow: preferredWindow) else { return nil }
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
        workspace.newCloudVPNSetupSurface(inPane: paneID, coordinator: cloudTunnelCoordinator, focus: focus) != nil else {
            manager.closeWorkspace(workspace, recordHistory: false)
            return nil
        }
        _ = workspace.closePanel(initialPanelID, force: true)
        return workspace
    }
}
