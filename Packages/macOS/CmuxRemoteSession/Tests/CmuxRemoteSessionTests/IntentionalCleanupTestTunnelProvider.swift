import CmuxCore
import CmuxRemoteWorkspace
import Foundation

/// Supplies the single recording tunnel used by intentional-cleanup tests.
final class IntentionalCleanupTestTunnelProvider: RemoteProxyTunnelProviding, @unchecked Sendable {
    let tunnel = IntentionalCleanupTestTunnel()

    func makeTunnel(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        onFatalError: @escaping @Sendable (String) -> Void
    ) -> any RemoteProxyTunneling {
        tunnel
    }
}
