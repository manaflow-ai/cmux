import CmuxCore
import CmuxRemoteWorkspace
import Foundation

/// Supplies the single recording tunnel used by intentional-cleanup tests.
final class IntentionalCleanupTestTunnelProvider: RemoteProxyTunnelProviding, @unchecked Sendable {
    let tunnel = IntentionalCleanupTestTunnel()
    private let lock = NSLock()
    private var _makeCount = 0

    var makeCount: Int { lock.withLock { _makeCount } }

    func makeTunnel(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        onFatalError: @escaping @Sendable (String) -> Void
    ) -> any RemoteProxyTunneling {
        lock.withLock { _makeCount += 1 }
        return tunnel
    }
}
