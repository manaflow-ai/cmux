import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteSession
import Foundation

/// Records runtime-state publications after callers drain the coordinator queue.
final class RuntimeStateRecordingHost: RemoteSessionHosting, @unchecked Sendable {
    // The coordinator queue is the only writer; tests read after queue.sync,
    // which is the happens-before edge for this focused fake.
    nonisolated(unsafe) var documents: [RemoteRuntimeStateDocument] = []
    nonisolated(unsafe) var revisions: [UInt64] = []

    func publishConnectionState(_: WorkspaceRemoteConnectionState, detail _: String?) {}
    func publishDaemonStatus(_: WorkspaceRemoteDaemonStatus) {}
    func publishProxyEndpoint(_: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel _: [UUID: [Int]], detected _: [Int]) {}
    func publishHeartbeat(count _: Int, lastSeenAt _: Date?) {}
    func publishBootstrapRemoteTTY(_: String) {}
    func publishRuntimeState(_ document: RemoteRuntimeStateDocument) { documents.append(document) }
    func publishRuntimeStateRevision(_ revision: UInt64) { revisions.append(revision) }
}
