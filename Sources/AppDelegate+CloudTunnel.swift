import AppKit

/// Composition of the app-managed Cloud tunnel: built once at startup next to
/// the other Cloud clients, handed to ``VMClient`` as the private-network gate
/// and to ``TerminalController`` for the `vm.tunnel_*` socket verbs.
///
/// ``CloudActivationPolicy`` is the one decision every tunnel consumer flows
/// through: it is built here from local state only, gates every start inside
/// the coordinator, decides whether the NetworkExtension controller may exist
/// at launch, and brings the tunnel down when Cloud Machines is turned off.
extension AppDelegate {
    @MainActor
    func makeCloudTunnelCoordinator() -> CloudTunnelCoordinator {
        let tunnelManager = VMTunnelManager()
        let activation = CloudActivationPolicy.live(browserTunnel: tunnelManager)
        let coordinator = CloudTunnelCoordinator.live(
            consumers: CloudTunnelAppConsumers(
                cloudBrowserCount: { [weak self] in
                    self?.cloudVMBrowserCount() ?? 0
                }
            ),
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

    /// Workspaces bound to a Cloud machine across every window: attached
    /// panes, `cmux vm tui` and `vm ssh` terminals the app hosts. Each one is a
    /// live consumer of the private network for the idle policy.
    @MainActor
    func cloudVMWorkspaceCount() -> Int {
        var managers: [TabManager] = mainWindowContexts.values.map(\.tabManager)
        if let tabManager, !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        var count = 0
        for manager in managers {
            for workspace in manager.workspacesById.values where workspace.isManagedCloudVMWorkspace {
                count += 1
            }
        }
        return count
    }

    /// Browser panels on Cloud machines are the only long-lived consumers of
    /// the system Network Extension. Terminal panels use the user-space hub.
    @MainActor
    func cloudVMBrowserCount() -> Int {
        var managers: [TabManager] = mainWindowContexts.values.map(\.tabManager)
        if let tabManager, !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        return managers.reduce(into: 0) { count, manager in
            for workspace in manager.workspacesById.values where workspace.isManagedCloudVMWorkspace {
                count += workspace.panels.values.filter { $0.panelType == .browser }.count
            }
        }
    }
}
