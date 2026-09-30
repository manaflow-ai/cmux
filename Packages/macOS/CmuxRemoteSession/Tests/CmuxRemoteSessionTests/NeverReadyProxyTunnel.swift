import CmuxRemoteWorkspace
import Foundation

/// A proxy tunnel that can never start, so its broker reports a retrying
/// error forever and never publishes an endpoint.
final class NeverReadyProxyTunnel: RemoteProxyTunneling {
    func start() throws {
        throw NSError(domain: "cmux.remote.proxy.test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "daemon transport refused the proxy stream",
        ])
    }

    func stop() {}

    func stopPreservingPTYLifecycle() -> RemotePTYLifecycleSnapshot {
        RemotePTYLifecycleSnapshot()
    }

    func restorePTYLifecycle(_ snapshot: RemotePTYLifecycleSnapshot) {}

    func listPTY() throws -> [[String: Any]] { [] }

    func closePTY(sessionID: String, deadline: DispatchTime) throws {}

    func ptySessionLifecycle(
        sessionID: String,
        lifecycleID: String
    ) -> RemotePTYSessionLifecycle { .active }

    func acknowledgePTYLifecycle(sessionID: String, lifecycleID: String) {}

    func acknowledgePTYLifecycleIfKnown(
        sessionID: String,
        lifecycleID: String
    ) -> Bool { false }

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
        throw NSError(domain: "cmux.remote.proxy.test", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "a tunnel that never started cannot bridge a PTY",
        ])
    }
}
