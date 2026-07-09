import CmuxRemoteWorkspace
import Foundation

/// Records PTY calls while presenting a ready in-memory tunnel to the session coordinator.
final class IntentionalCleanupTestTunnel: RemoteProxyTunneling, @unchecked Sendable {
    struct Call: Equatable {
        let name: String
        let sessionID: String
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var bridgeServers: [RemotePTYBridgeServer] = []
    private var shouldFailClose = false

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func failCloseRequests() {
        lock.withLock {
            shouldFailClose = true
        }
    }

    func start() throws {}
    func stop() {
        let servers = lock.withLock {
            let servers = bridgeServers
            bridgeServers.removeAll()
            return servers
        }
        for server in servers {
            server.stop()
        }
    }

    func listPTY() throws -> [[String: Any]] {
        []
    }

    func closePTY(sessionID: String) throws {
        record(name: "close", sessionID: sessionID)
        if lock.withLock({ shouldFailClose }) {
            throw NSError(domain: "cmux.tests.intentional-cleanup", code: 1)
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
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> RemotePTYBridgeServer.Endpoint {
        record(name: "bridge", sessionID: sessionID)
        let server = RemotePTYBridgeServer(
            rpcClient: IntentionalCleanupBridgeRPCClient(),
            sessionID: sessionID,
            attachmentID: attachmentID,
            command: command,
            requireExisting: requireExisting,
            strings: IntentionalCleanupBridgeStrings(),
            onStop: {}
        )
        let endpoint = try server.start()
        lock.withLock {
            bridgeServers.append(server)
        }
        return endpoint
    }

    private func record(name: String, sessionID: String) {
        lock.withLock {
            recordedCalls.append(Call(name: name, sessionID: sessionID))
        }
    }
}
