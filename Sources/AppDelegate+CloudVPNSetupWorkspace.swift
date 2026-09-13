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
        return CloudVPNSetupNavigation(coordinator: cloudTunnelCoordinator).open(in: manager, focus: focus)
    }
}
