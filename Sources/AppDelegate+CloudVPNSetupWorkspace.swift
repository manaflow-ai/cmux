import AppKit
import CmuxSettings

extension AppDelegate {
    @objc func openCloudVPNSetupMenuItem(_ sender: NSMenuItem) {
        guard let windowID = sender.representedObject as? UUID,
              let context = mainWindowContexts.values.first(where: { $0.windowId == windowID }) else { return }
        openCloudVPNSetupWorkspace(preferredTabManager: context.tabManager, preferredWindow: context.window)
    }

    /// Opens the optional Cloud VPN guide as a normal cmux pane. All entry
    /// points use this method so the Machines panel and context menu behave the
    /// same way as the iOS pairing pane.
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
