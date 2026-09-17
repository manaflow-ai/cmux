import CmuxCore
import Foundation
@testable import CmuxRemoteSession

/// Streams every published connection state so a test can await the session's
/// terminal transition instead of sleeping or polling for it.
final class ReadinessRecordingHost: RemoteSessionHosting, Sendable {
    let connectionStates: AsyncStream<ReadinessConnectionPublication>
    private let continuation: AsyncStream<ReadinessConnectionPublication>.Continuation

    init() {
        (connectionStates, continuation) = AsyncStream.makeStream()
    }

    func publishConnectionState(
        _ state: WorkspaceRemoteConnectionState,
        detail: String?
    ) {
        continuation.yield(
            ReadinessConnectionPublication(state: state, detail: detail)
        )
    }

    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {}
    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int]) {}
    func publishHeartbeat(count: Int, lastSeenAt: Date?) {}
    func publishBootstrapRemoteTTY(_ ttyName: String) {}

    /// Returns the first publication of `state`, consuming earlier ones.
    func firstPublication(
        of state: WorkspaceRemoteConnectionState
    ) async -> ReadinessConnectionPublication? {
        for await publication in connectionStates where publication.state == state {
            return publication
        }
        return nil
    }
}
