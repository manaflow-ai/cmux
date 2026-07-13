import CmuxRemoteWorkspace
import Foundation

/// Shared fake whose lifecycle table models the tunnel-owned coordinator seam.
final class IntentionalCleanupTestTunnel: RemoteProxyTunneling, @unchecked Sendable {
    private let lock = NSLock()
    private var lifecycleByKey: [IntentionalCleanupTestTunnelKey: RemotePTYSessionLifecycle] = [:]
    private var bridgeServers: [(sessionID: String, server: RemotePTYBridgeServer)] = []

    func start() throws {}

    func stop() {
        let servers = lock.withLock {
            let servers = bridgeServers
            bridgeServers.removeAll()
            lifecycleByKey.removeAll()
            return servers
        }
        for record in servers { record.server.stop() }
    }

    func stopPreservingPTYLifecycle() -> RemotePTYLifecycleSnapshot {
        stop()
        return RemotePTYLifecycleSnapshot()
    }

    func restorePTYLifecycle(_ snapshot: RemotePTYLifecycleSnapshot) {}

    func listPTY() throws -> [[String: Any]] { [] }

    func closePTY(sessionID: String, deadline: DispatchTime) throws {
        let servers = lock.withLock {
            for key in lifecycleByKey.keys where key.sessionID == sessionID {
                lifecycleByKey[key] = .intentionallyClosed
            }
            let servers = bridgeServers.filter { $0.sessionID == sessionID }
            bridgeServers.removeAll { $0.sessionID == sessionID }
            return servers
        }
        for record in servers { record.server.stop() }
    }

    func ptySessionLifecycle(sessionID: String, lifecycleID: String) -> RemotePTYSessionLifecycle {
        lock.withLock {
            lifecycleByKey[
                IntentionalCleanupTestTunnelKey(sessionID: sessionID, lifecycleID: lifecycleID)
            ] ?? .active
        }
    }

    func acknowledgePTYLifecycle(sessionID: String, lifecycleID: String) {
        lock.withLock {
            lifecycleByKey[
                IntentionalCleanupTestTunnelKey(sessionID: sessionID, lifecycleID: lifecycleID)
            ] = .intentionallyClosed
        }
    }

    func acknowledgePTYLifecycleIfKnown(sessionID: String, lifecycleID: String) -> Bool {
        lock.withLock {
            let key = IntentionalCleanupTestTunnelKey(sessionID: sessionID, lifecycleID: lifecycleID)
            guard lifecycleByKey[key] != nil else { return false }
            lifecycleByKey[key] = .intentionallyClosed
            return true
        }
    }

    func resizePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        cols: Int,
        rows: Int
    ) throws {}

    func detachPTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String
    ) throws {}

    func startPTYBridge(
        sessionID: String,
        lifecycleID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool,
        onLifecycleEnded: @escaping @Sendable () -> Void
    ) throws -> RemotePTYBridgeServer.Endpoint {
        let key = IntentionalCleanupTestTunnelKey(sessionID: sessionID, lifecycleID: lifecycleID)
        if lock.withLock({ lifecycleByKey[key] == .intentionallyClosed }) {
            throw RemotePTYLifecycleError.intentionallyClosed
        }
        let server = RemotePTYBridgeServer(
            rpcClient: IntentionalCleanupBridgeRPCClient(),
            sessionID: sessionID,
            lifecycleID: lifecycleID,
            attachmentID: attachmentID,
            command: command,
            requireExisting: requireExisting,
            strings: IntentionalCleanupBridgeStrings(),
            onStop: { _ in }
        )
        let endpoint = try server.start()
        lock.withLock {
            lifecycleByKey[key] = .active
            bridgeServers.append((sessionID: sessionID, server: server))
        }
        return endpoint
    }
}
