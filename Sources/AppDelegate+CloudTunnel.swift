import CmuxCloud
import CmuxSettings
import AppKit

/// Composition of the app-managed Cloud tunnel: built once at startup next to
/// the other Cloud clients, and handed to ``TerminalController`` for the
/// explicit `vm.tunnel_*` socket verbs.
///
/// ``CloudActivationPolicy`` is the one decision every tunnel consumer flows
/// through: it is built here from local state only, gates every start inside
/// the coordinator, decides whether the NetworkExtension controller may exist
/// at launch, and brings the tunnel down when Cloud Machines is turned off.
extension AppDelegate {
    /// Opens Cloud VPN setup as a pane in its own workspace, or focuses the one
    /// already open. Ports and Settings both call this; only the pane's
    /// controls activate the VPN. Settings passes `bringWindowForward` because
    /// it runs in its own window.
    @MainActor
    @discardableResult
    func openCloudVPNSetup(preferredWindow: NSWindow? = nil, bringWindowForward: Bool = false) -> CloudVPNSetupPanel? {
        guard CloudMachinesFeature.isAvailable,
              !ManagedDevicePolicy().isEnforced(.disableCloud),
              let manager = synchronizeActiveMainWindowContext(preferredWindow: preferredWindow) else {
            return nil
        }
        guard CloudMachinesFeature.isEnabled else {
            _ = focusRightSidebarInActiveMainWindow(mode: .machines)
            return nil
        }
        if bringWindowForward {
            guard let context = mainWindowContext(for: manager),
                  let window = resolvedWindow(for: context),
                  focusWindowForAppActivation(window, reason: .workspaceCreation) else {
                return nil
            }
        }
        for workspace in manager.tabs {
            guard let panel = workspace.panels.values.lazy.compactMap({ $0 as? CloudVPNSetupPanel }).first else {
                continue
            }
            if let cloudTunnelCoordinator { panel.model.attachIfNeeded(cloudTunnelCoordinator) }
            manager.selectedTabId = workspace.id
            workspace.focusPanel(panel.id)
            return panel
        }

        guard let workspace = manager.addWorkspaceIfActive(
            title: String(localized: "cloud.vpn.setup.title", defaultValue: "Cloud VPN"),
            select: true,
            eagerLoadTerminal: false,
            autoWelcomeIfNeeded: false,
            autoRefreshMetadata: false,
            allowTextBoxFocusDefault: false
        ) else {
            return nil
        }
        guard let initialPanelID = workspace.focusedPanelId,
              let paneID = workspace.paneId(forPanelId: initialPanelID),
              let panel = workspace.newCloudVPNSetupSurface(
                inPane: paneID, coordinator: cloudTunnelCoordinator, focus: true) else {
            manager.closeWorkspace(workspace, recordHistory: false)
            return nil
        }
        _ = workspace.closePanel(initialPanelID, force: true)
        return panel
    }

    @MainActor
    func makeCloudTunnelCoordinator() -> CloudTunnelCoordinator {
        let tunnelManager = VMTunnelManager()
        let activation = CloudActivationPolicy.live(
            browserTunnel: tunnelManager,
            remoteEnabled: { CmuxFeatureFlags.offMainEffectiveValue(for: CmuxFeatureFlags.cloudMachinesFlag) }
        )
        let coordinator = CloudTunnelCoordinator.live(
            consumers: CloudTunnelAppConsumers(),
            tunnelManager: tunnelManager,
            activation: activation
        )
        cloudTunnelActivationObserver = CloudTunnelActivationObserver(
            isStartRefused: { activation.tunnelStartRefusal() != nil },
            bringDown: { await coordinator.requestDown() }
        )
        return coordinator
    }

    /// Signing out ends every Cloud session at once; the tunnel goes with it.
    @MainActor
    func cloudTunnelAccessDidEnd() {
        VMTunnelManager(purpose: .browser).removeLocalCredentials()
        VMTunnelManager(purpose: .terminal).removeLocalCredentials()
        // The next account starts from "no machine known": nothing Cloud runs
        // at launch until it opts in or this Mac lists its fleet again.
        CloudMachineCache().clear()
        guard let coordinator = cloudTunnelCoordinator else { return }
        let previous = cloudTunnelTeardownTask
        cloudTunnelTeardownTask = Task {
            await previous?.value
            try? await coordinator.revoke()
        }
    }

}
