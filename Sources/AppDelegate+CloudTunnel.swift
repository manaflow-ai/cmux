import AppKit

/// Composition of the app-managed Cloud tunnel: built once at startup next to
/// the other Cloud clients, handed to ``VMClient`` as the private-network gate
/// and to ``TerminalController`` for the `vm.tunnel_*` socket verbs.
extension AppDelegate {
    @MainActor
    func makeCloudTunnelCoordinator() -> CloudTunnelCoordinator {
        CloudTunnelCoordinator.live(
            consumers: CloudTunnelAppConsumers(
                cloudWorkspaceCount: { [weak self] in
                    self?.cloudVMWorkspaceCount() ?? 0
                },
                connectedLinkCount: {
                    await CmuxTuiSurfaceProviderRegistry.shared.connectedCloudLinkCount()
                }
            )
        )
    }

    /// Signing out ends every Cloud session at once; the tunnel goes with it.
    @MainActor
    func cloudTunnelAccessDidEnd() {
        guard let coordinator = cloudTunnelCoordinator else { return }
        cloudTunnelTeardownTask?.cancel()
        cloudTunnelTeardownTask = Task {
            await coordinator.accessDidEnd()
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
}
