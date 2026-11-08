import CmuxCore
import Foundation
@testable import CmuxRemoteSession

final class ReverseRelayRecoveryHost:
    RemoteSessionHosting,
    @unchecked Sendable
{
    let daemonStatuses: AsyncStream<WorkspaceRemoteDaemonStatus>
    private let daemonStatusContinuation:
        AsyncStream<WorkspaceRemoteDaemonStatus>.Continuation

    init() {
        (daemonStatuses, daemonStatusContinuation) = AsyncStream.makeStream()
    }

    func publishConnectionState(
        _ state: WorkspaceRemoteConnectionState,
        detail: String?
    ) {}

    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {
        daemonStatusContinuation.yield(status)
    }

    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {}

    func publishPortsSnapshot(
        detectedByPanel: [UUID: [Int]],
        detected: [Int]
    ) {}

    func publishHeartbeat(count: Int, lastSeenAt: Date?) {}
    func publishBootstrapRemoteTTY(_ ttyName: String) {}
}
