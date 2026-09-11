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
    @MainActor
    func makeCloudTunnelCoordinator() -> CloudTunnelCoordinator {
        let tunnelManager = VMTunnelManager()
        let activation = CloudActivationPolicy.live(browserTunnel: tunnelManager)
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
