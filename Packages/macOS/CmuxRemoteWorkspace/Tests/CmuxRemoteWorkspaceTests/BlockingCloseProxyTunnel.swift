import Foundation
@testable import CmuxRemoteWorkspace

/// Test fake whose immutable semaphore references provide thread-safe signaling.
final class BlockingCloseProxyTunnel: RemoteProxyTunneling, @unchecked Sendable {
    private let closeStarted = DispatchSemaphore(value: 0)
    private let closeRelease = DispatchSemaphore(value: 0)
    private let listReached = DispatchSemaphore(value: 0)

    func waitForCloseStart() -> DispatchTimeoutResult {
        closeStarted.wait(timeout: .now() + 2)
    }

    func releaseClose() {
        closeRelease.signal()
    }

    func waitForList() -> DispatchTimeoutResult {
        listReached.wait(timeout: .now() + 2)
    }

    func start() throws {}
    func stop() {}
    func stopPreservingPTYLifecycle() -> RemotePTYLifecycleSnapshot { RemotePTYLifecycleSnapshot() }
    func restorePTYLifecycle(_ snapshot: RemotePTYLifecycleSnapshot) {}

    func listPTY() throws -> [[String: Any]] {
        listReached.signal()
        return []
    }

    func closePTY(sessionID: String, deadline: DispatchTime) throws {
        closeStarted.signal()
        closeRelease.wait()
    }

    func ptySessionLifecycle(sessionID: String, lifecycleID: String) -> RemotePTYSessionLifecycle {
        .active
    }

    func acknowledgePTYLifecycle(sessionID: String, lifecycleID: String) {}
    func acknowledgePTYLifecycleIfKnown(sessionID: String, lifecycleID: String) -> Bool { false }

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
        throw NSError(domain: "test", code: 1)
    }
}
