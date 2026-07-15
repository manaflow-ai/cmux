import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteSession
import Foundation

// The app-side conformer of the session coordinator's publish seam. Owns
// exactly what the legacy controller's publish helpers owned: the weak
// workspace reference, the main-queue hop, the stale-controller guard
// (`activeRemoteSessionControllerID`), and the `remoteDisplayTarget` fallback.
// Synchronous methods may be called from the coordinator's serial queue; the
// async runtime-state methods are awaited from a coordinator-owned task.
//
// `@unchecked Sendable`: `controllerID` is immutable and `workspace` is a
// weak reference that is only assigned in `init`; afterwards it is read via
// `[weak workspace]` captures (weak loads are runtime-atomic) and the
// referenced `Workspace` is only touched after hopping to the main queue.
final class WorkspaceRemoteSessionHostAdapter: RemoteSessionHosting, @unchecked Sendable {
    private weak var workspace: Workspace?
    private let controllerID: UUID

    init(workspace: Workspace, controllerID: UUID) {
        self.workspace = workspace
        self.controllerID = controllerID
    }

    func publishConnectionState(_ state: WorkspaceRemoteConnectionState, detail: String?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteConnectionStateUpdate(
                state,
                detail: detail,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteDaemonStatusUpdate(
                status,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteProxyEndpointUpdate(endpoint)
        }
    }

    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int]) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteDetectedSurfacePortsSnapshot(
                detectedByPanel: detectedByPanel,
                detected: detected,
                forwarded: [],
                conflicts: [],
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    func publishHeartbeat(count: Int, lastSeenAt: Date?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteHeartbeatUpdate(count: count, lastSeenAt: lastSeenAt)
        }
    }

    func publishBootstrapRemoteTTY(_ ttyName: String) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyBootstrapRemoteTTY(ttyName)
        }
    }

    func publishRuntimeState(_ document: RemoteRuntimeStateDocument) async {
        guard !Task.isCancelled,
              document.schemaVersion == SessionSnapshotSchema.currentVersion,
              let snapshot = try? JSONDecoder().decode(
                  SessionWorkspaceSnapshot.self,
                  from: document.state
              ),
              !Task.isCancelled else { return }
        let controllerID = self.controllerID
        await MainActor.run { [weak workspace] in
            guard !Task.isCancelled else { return }
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteRuntimeState(document, snapshot: snapshot)
        }
    }

    func publishRuntimeStateRevision(_ revision: UInt64) async {
        let controllerID = self.controllerID
        await MainActor.run { [weak workspace] in
            guard !Task.isCancelled else { return }
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.acknowledgeRemoteRuntimeStateRevision(revision)
        }
    }
}
