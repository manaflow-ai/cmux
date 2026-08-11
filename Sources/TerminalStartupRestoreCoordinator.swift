import CmuxAgentChat
import CmuxTerminal
import CmuxWorkspaces
import Foundation

/// Commits structured terminal restores after their owning topology is authoritative.
@MainActor
final class TerminalStartupRestoreCoordinator {
    private struct PendingRestore {
        let panel: TerminalPanel
        let snapshot: SessionRestorableAgentSnapshot?
        let manualResumeAvailable: Bool
        let willRunStartupCommand: Bool
        let willRunStartupInput: Bool
        let resumeWorkingDirectory: String?
        let resumeIntent: AgentChatResumeIntent?

        var willRunStartupWork: Bool {
            willRunStartupCommand || willRunStartupInput
        }
    }

    let lifecycle: RestoredAgentLifecycleCoordinator

    private let workspaceID: UUID
    private let resumeIntentRecorder: any AgentChatResumeIntentRecording
    private var pendingRestoresByPanelID: [UUID: PendingRestore] = [:]

    /// Creates one restore owner for a workspace or Dock terminal container.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace identity used by authoritative chat bindings.
    ///   - lifecycle: Lifecycle state updated when a staged restore commits.
    ///   - resumeIntentRecorder: Adapter receiving committed chat bindings.
    init(
        workspaceID: UUID,
        lifecycle: RestoredAgentLifecycleCoordinator,
        resumeIntentRecorder: any AgentChatResumeIntentRecording
    ) {
        self.workspaceID = workspaceID
        self.lifecycle = lifecycle
        self.resumeIntentRecorder = resumeIntentRecorder
    }

    /// Adds a topology commit gate without changing immediate-versus-paced startup timing.
    ///
    /// - Parameters:
    ///   - requestedPolicy: Timing policy selected by the terminal creation path.
    ///   - willRunStartupCommand: Whether a restored agent command will run.
    ///   - willRunStartupInput: Whether a restored agent selector will be queued.
    /// - Returns: The requested policy with a restore gate when one is required.
    nonisolated func runtimeSpawnPolicy(
        requestedPolicy: TerminalSurfaceRuntimeSpawnPolicy,
        willRunStartupCommand: Bool,
        willRunStartupInput: Bool
    ) -> TerminalSurfaceRuntimeSpawnPolicy {
        willRunStartupCommand || willRunStartupInput
            ? requestedPolicy.requiringStartupRestoreAdmission()
            : requestedPolicy
    }

    /// Stages lifecycle and chat state for a terminal that has joined its local panel tree.
    ///
    /// Staging never starts the terminal runtime. The topology owner must call
    /// ``commitPendingRestores(panelIDs:)`` after publishing the containing
    /// workspace, split, or Dock layout.
    ///
    /// - Parameters:
    ///   - panel: Terminal receiving the structured restore.
    ///   - snapshot: Persisted agent launch data, when one is available.
    ///   - resumeBinding: Hook-owned fallback identity for snapshots without an agent payload.
    ///   - manualResumeAvailable: Whether the terminal retains a manual continuation.
    ///   - willRunStartupCommand: Whether an agent restore starts as a terminal command.
    ///   - willRunStartupInput: Whether an agent restore selector is queued as terminal input.
    ///   - resumeWorkingDirectory: Working directory owned by the resumed agent launch.
    ///   - chatWorkingDirectory: Working directory used to resolve the resumed transcript.
    ///   - agentSessionAlreadyActive: Whether another surface already owns the live session.
    func stage(
        panel: TerminalPanel,
        snapshot: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil,
        manualResumeAvailable: Bool,
        willRunStartupCommand: Bool,
        willRunStartupInput: Bool,
        resumeWorkingDirectory: String?,
        chatWorkingDirectory: String? = nil,
        agentSessionAlreadyActive: Bool = false
    ) {
        pendingRestoresByPanelID[panel.id] = PendingRestore(
            panel: panel,
            snapshot: snapshot,
            manualResumeAvailable: manualResumeAvailable,
            willRunStartupCommand: willRunStartupCommand,
            willRunStartupInput: willRunStartupInput,
            resumeWorkingDirectory: resumeWorkingDirectory,
            resumeIntent: resumeIntent(
                panelID: panel.id,
                snapshot: snapshot,
                resumeBinding: resumeBinding,
                workingDirectory: chatWorkingDirectory ?? resumeWorkingDirectory,
                agentSessionAlreadyActive: agentSessionAlreadyActive
            )
        )
    }

    /// Atomically commits staged restore state before releasing terminal runtimes.
    ///
    /// - Parameter panelIDs: Specific staged panels to commit, or `nil` for every pending panel.
    func commitPendingRestores(panelIDs: [UUID]? = nil) {
        let commitPanelIDs = panelIDs ?? Array(pendingRestoresByPanelID.keys)
        for panelID in commitPanelIDs {
            guard let pending = pendingRestoresByPanelID.removeValue(forKey: panelID) else {
                continue
            }
            lifecycle.seedSessionRestore(
                panelId: panelID,
                snapshot: pending.snapshot,
                manualResumeAvailable: pending.manualResumeAvailable,
                willRunStartupCommand: pending.willRunStartupCommand,
                willRunStartupInput: pending.willRunStartupInput,
                resumeWorkingDirectory: pending.resumeWorkingDirectory
            )
            if let resumeIntent = pending.resumeIntent {
                resumeIntentRecorder.record(resumeIntent)
#if DEBUG
                cmuxDebugLog(
                    "session.restore.resumeBinding workspace=\(workspaceID.uuidString.prefix(8)) " +
                    "surface=\(panelID.uuidString.prefix(8)) source=\(resumeIntent.source) " +
                    "session=\(resumeIntent.sessionID.prefix(8))"
                )
#endif
            }
            if pending.willRunStartupWork {
                pending.panel.surface.admitStartupRestoreRuntime()
            }
        }
    }

    /// Drops staged transactions and clears all committed lifecycle metadata.
    func removeAllRestores() {
        pendingRestoresByPanelID.removeAll(keepingCapacity: false)
        lifecycle.removeAllSessionRestores()
    }

    private func resumeIntent(
        panelID: UUID,
        snapshot: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        workingDirectory: String?,
        agentSessionAlreadyActive: Bool
    ) -> AgentChatResumeIntent? {
        guard !agentSessionAlreadyActive else { return nil }

        let session: (id: String, source: String)?
        if let snapshot {
            session = (snapshot.sessionId, snapshot.kind.rawValue)
        } else if resumeBinding?.isAgentHookBinding == true,
                  let id = resumeBinding?.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  let source = resumeBinding?.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty {
            session = (id, source)
        } else {
            session = nil
        }
        guard let session else { return nil }

        return AgentChatResumeIntent(
            sessionID: session.id,
            source: session.source,
            surfaceID: panelID.uuidString,
            workspaceID: workspaceID.uuidString,
            workingDirectory: workingDirectory
        )
    }
}
