import CmuxCore
import CmuxRemoteWorkspace

/// Hands the broker a fresh ``NeverReadyProxyTunnel`` for every restart.
struct NeverReadyProxyTunnelProvider: RemoteProxyTunnelProviding {
    func makeTunnel(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        onFatalError: @escaping @Sendable (String) -> Void
    ) -> any RemoteProxyTunneling {
        NeverReadyProxyTunnel()
    }
}
