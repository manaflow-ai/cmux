import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation

/// Shared fake whose lifecycle table models the tunnel-owned coordinator seam.
final class IntentionalCleanupTestTunnel: RemoteProxyTunneling, @unchecked Sendable {
    private let lock = NSLock()
    private var lifecycleByKey: [IntentionalCleanupTestTunnelKey: RemotePTYSessionLifecycle] = [:]
    private var bridgeServers: [(sessionID: String, server: RemotePTYBridgeServer)] = []
    private var runtimeState: RemoteRuntimeStateDocument?
    private var runtimeStateGetFailuresRemaining = 0
    private var runtimeStatePutFailuresRemaining = 0
    private var runtimeStateGetBlock: (started: DispatchSemaphore, release: DispatchSemaphore)?
    private var runtimeStatePutBlock: (started: DispatchSemaphore, release: DispatchSemaphore)?
    private var runtimeStateSubscriber: (@Sendable (RemoteRuntimeStateDocument) -> Void)?

    func start() throws {}

    func stop() {
        let servers = lock.withLock {
            let servers = bridgeServers
            bridgeServers.removeAll()
            lifecycleByKey.removeAll()
            runtimeStateSubscriber = nil
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

    func getRuntimeState() throws -> RemoteRuntimeStateDocument? {
        let block = lock.withLock {
            defer { runtimeStateGetBlock = nil }
            return runtimeStateGetBlock
        }
        block?.started.signal()
        block?.release.wait()
        return try lock.withLock {
            if runtimeStateGetFailuresRemaining > 0 {
                runtimeStateGetFailuresRemaining -= 1
                throw NSError(domain: "test.runtime-state", code: 2)
            }
            return runtimeState
        }
    }

    func putRuntimeState(
        schemaVersion: Int,
        state: Data,
        expectedRevision: UInt64?
    ) throws -> RemoteRuntimeStateDocument {
        let block = lock.withLock {
            defer { runtimeStatePutBlock = nil }
            return runtimeStatePutBlock
        }
        block?.started.signal()
        block?.release.wait()
        let (document, subscriber) = try lock.withLock {
            if runtimeStatePutFailuresRemaining > 0 {
                runtimeStatePutFailuresRemaining -= 1
                throw NSError(domain: "test.runtime-state", code: 3)
            }
            let currentRevision = runtimeState?.revision ?? 0
            if let expectedRevision, expectedRevision != currentRevision {
                throw NSError(domain: "test.runtime-state", code: 1)
            }
            let document = RemoteRuntimeStateDocument(
                schemaVersion: schemaVersion,
                revision: currentRevision + 1,
                updatedAtUnixMilliseconds: 1,
                state: state,
                ptySessions: Data("[]".utf8)
            )
            runtimeState = document
            return (document, runtimeStateSubscriber)
        }
        subscriber?(document)
        return document
    }

    func subscribeRuntimeState(
        queue: DispatchQueue,
        onDocument: @escaping @Sendable (RemoteRuntimeStateDocument) -> Void
    ) throws -> RemoteRuntimeStateDocument? {
        lock.withLock {
            runtimeStateSubscriber = { document in
                queue.sync {
                    onDocument(document)
                }
            }
            return runtimeState
        }
    }

    func seedRuntimeState(_ document: RemoteRuntimeStateDocument?) {
        lock.withLock { runtimeState = document }
    }

    func failNextRuntimeStateGet() {
        failNextRuntimeStateGets(1)
    }

    func failNextRuntimeStateGets(_ count: Int) {
        precondition(count >= 0)
        lock.withLock { runtimeStateGetFailuresRemaining += count }
    }

    func clearRuntimeStateGetFailures() {
        lock.withLock { runtimeStateGetFailuresRemaining = 0 }
    }

    func failNextRuntimeStatePut() {
        lock.withLock { runtimeStatePutFailuresRemaining += 1 }
    }

    func blockNextRuntimeStateGet(
        started: DispatchSemaphore,
        release: DispatchSemaphore
    ) {
        lock.withLock {
            runtimeStateGetBlock = (started: started, release: release)
        }
    }

    func blockNextRuntimeStatePut(
        started: DispatchSemaphore,
        release: DispatchSemaphore
    ) {
        lock.withLock {
            runtimeStatePutBlock = (started: started, release: release)
        }
    }

    func publishRuntimeState(_ document: RemoteRuntimeStateDocument) {
        let subscriber = lock.withLock {
            runtimeState = document
            return runtimeStateSubscriber
        }
        subscriber?(document)
    }

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
