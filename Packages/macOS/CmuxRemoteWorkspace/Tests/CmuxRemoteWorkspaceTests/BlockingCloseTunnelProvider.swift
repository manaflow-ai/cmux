import CmuxCore
@testable import CmuxRemoteWorkspace

/// Test provider holding one thread-safe blocking tunnel fake.
final class BlockingCloseTunnelProvider: RemoteProxyTunnelProviding, @unchecked Sendable {
    private let tunnel: BlockingCloseProxyTunnel

    init(tunnel: BlockingCloseProxyTunnel) {
        self.tunnel = tunnel
    }

    func makeTunnel(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        onFatalError: @escaping @Sendable (String) -> Void
    ) -> any RemoteProxyTunneling {
        tunnel
    }
}
