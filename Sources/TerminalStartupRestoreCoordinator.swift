import CmuxAgentChat
import CmuxTerminal
import CmuxWorkspaces
import Foundation

/// Commits structured terminal restores after their owning topology is authoritative.
@MainActor
final class TerminalStartupRestoreCoordinator {
    let lifecycle: RestoredAgentLifecycleCoordinator

    private let workspaceID: UUID
    private let resumeIntentRecorder: any AgentChatResumeIntentRecording
    private var pendingRestoresByPanelID: [UUID: PendingTerminalStartupRestore] = [:]

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
    ///   - awaitsDeferredAgentResume: Whether the ownership scan must decide
    ///     the first runtime's resume command after topology commit.
    /// - Returns: The requested policy with a restore gate when one is required.
    nonisolated func runtimeSpawnPolicy(
        requestedPolicy: TerminalSurfaceRuntimeSpawnPolicy,
        willRunStartupCommand: Bool,
        willRunStartupInput: Bool,
        awaitsDeferredAgentResume: Bool = false
    ) -> TerminalSurfaceRuntimeSpawnPolicy {
        if awaitsDeferredAgentResume {
            return requestedPolicy.requiringDeferredAgentResumeAdmission()
        }
        return willRunStartupCommand || willRunStartupInput
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
    ///   - ownsResumeLaunchClaim: Whether this transaction claimed the agent resume launch.
    ///   - defersStartupRestoreAdmission: Whether ownership resolution must
    ///     admit or cancel the runtime after the topology commit.
    func stage(
        panel: TerminalPanel,
        snapshot: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil,
        manualResumeAvailable: Bool,
        willRunStartupCommand: Bool,
        willRunStartupInput: Bool,
        resumeWorkingDirectory: String?,
        chatWorkingDirectory: String? = nil,
        agentSessionAlreadyActive: Bool = false,
        ownsResumeLaunchClaim: Bool = false,
        defersStartupRestoreAdmission: Bool = false
    ) {
        pendingRestoresByPanelID[panel.id] = PendingTerminalStartupRestore(
            panel: panel,
            stagedWorkspaceID: panel.workspaceId,
            snapshot: snapshot,
            manualResumeAvailable: manualResumeAvailable,
            willRunStartupCommand: willRunStartupCommand,
            willRunStartupInput: willRunStartupInput,
            defersStartupRestoreAdmission: defersStartupRestoreAdmission,
            resumeWorkingDirectory: resumeWorkingDirectory,
            chatResumeBinding: chatResumeBinding(
                snapshot: snapshot,
                resumeBinding: resumeBinding,
                workingDirectory: chatWorkingDirectory ?? resumeWorkingDirectory,
                agentSessionAlreadyActive: agentSessionAlreadyActive
            ),
            ownedResumeLaunchClaim: ownsResumeLaunchClaim ? snapshot : nil
        )
    }

    /// Moves one staged transaction to the topology owner adopting its terminal.
    ///
    /// The destination remains responsible for committing after it publishes
    /// the transferred panel. Moving the transaction never admits the runtime.
    ///
    /// - Parameters:
    ///   - panelID: Panel whose staged restore ownership is moving.
    ///   - destination: Coordinator for the adopting topology.
    /// - Returns: Whether a staged transaction moved or was already owned by the destination.
    @discardableResult
    func transferPendingRestore(
        panelID: UUID,
        to destination: TerminalStartupRestoreCoordinator
    ) -> Bool {
        if self === destination {
            return pendingRestoresByPanelID[panelID] != nil
        }
        guard let pending = pendingRestoresByPanelID.removeValue(forKey: panelID) else {
            return false
        }
        destination.pendingRestoresByPanelID[panelID] = pending
        return true
    }

    /// Cancels one staged transaction whose terminal cannot join its destination topology.
    ///
    /// Cancellation releases only the resume-launch claim owned by this transaction,
    /// clears tracking for every owner the panel crossed, and tears down the held terminal
    /// so it cannot remain permanently admission-gated.
    ///
    /// - Parameter panelID: Panel whose staged restore can no longer commit.
    /// - Returns: Whether a staged transaction was cancelled.
    @discardableResult
    func cancelPendingRestore(panelID: UUID) -> Bool {
        guard let pending = removePendingRestore(panelID: panelID) else {
            return false
        }
        pending.panel.close()
        return true
    }

    /// Removes staged state while the topology owner performs the panel teardown.
    ///
    /// Unlike ``cancelPendingRestore(panelID:)``, this does not close the panel and
    /// therefore cannot recursively enter the owner's panel-destruction path.
    ///
    /// - Parameter panelID: Panel whose owning topology is already discarding it.
    /// - Returns: Whether a staged transaction was discarded.
    @discardableResult
    func discardPendingRestoreForPanelTeardown(panelID: UUID) -> Bool {
        removePendingRestore(panelID: panelID) != nil
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
            if let chatResumeBinding = pending.chatResumeBinding {
                let resumeIntent = chatResumeBinding.intent(
                    panelID: panelID,
                    workspaceID: workspaceID
                )
                resumeIntentRecorder.record(resumeIntent)
#if DEBUG
                cmuxDebugLog(
                    "session.restore.resumeBinding workspace=\(workspaceID.uuidString.prefix(8)) " +
                    "surface=\(panelID.uuidString.prefix(8)) source=\(resumeIntent.source) " +
                    "session=\(resumeIntent.sessionID.prefix(8))"
                )
#endif
            }
            if pending.willRunStartupWork, !pending.defersStartupRestoreAdmission {
                pending.panel.surface.admitStartupRestoreRuntime()
            }
        }
    }

    /// Cancels staged transactions and clears all committed lifecycle metadata.
    func removeAllRestores() {
        for panelID in Array(pendingRestoresByPanelID.keys) {
            cancelPendingRestore(panelID: panelID)
        }
        lifecycle.removeAllSessionRestores()
    }

    private func removePendingRestore(panelID: UUID) -> PendingTerminalStartupRestore? {
        guard let pending = pendingRestoresByPanelID.removeValue(forKey: panelID) else {
            return nil
        }
        if let claim = pending.ownedResumeLaunchClaim {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: claim.kind.rawValue,
                sessionId: claim.sessionId
            )
        }
        if pending.stagedWorkspaceID != pending.panel.workspaceId {
            AgentHibernationController.shared.discardTrackingStateForClosedPanel(
                workspaceId: pending.stagedWorkspaceID,
                panelId: pending.panel.id
            )
        }
        return pending
    }

    private func chatResumeBinding(
        snapshot: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        workingDirectory: String?,
        agentSessionAlreadyActive: Bool
    ) -> PendingTerminalStartupRestoreChatBinding? {
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

        return PendingTerminalStartupRestoreChatBinding(
            sessionID: session.id,
            source: session.source,
            workingDirectory: workingDirectory
        )
    }
}
