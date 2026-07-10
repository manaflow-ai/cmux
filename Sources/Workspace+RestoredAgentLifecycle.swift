import Foundation

/// Lifecycle rules for a panel's restored (resumable) agent snapshot.
///
/// The snapshot drives the tab's agent brand icon, fork availability, and the
/// restorable agent persisted for app relaunch, so its lifetime must track the
/// invariant behind https://github.com/manaflow-ai/cmux/issues/7822: a
/// plain-shell tab with no live agent and no pending restore shows the plain
/// terminal icon. Two rules enforce that here, for every agent kind:
///
/// - A snapshot may only be adopted from the persist-time hook index while
///   there is evidence the session is current (recorded agent runtime or a
///   running foreground command). Restore, hibernation, and Dock-detach
///   seeding are the only other ways in.
/// - Proof that a panel's recorded agent process died is an agent exit
///   signal, equivalent to the shell-activity machine observing the exit, and
///   invalidates the snapshot.
extension Workspace {
    /// Reconciles a persist-time indexed restorable-agent snapshot into the
    /// panel's in-memory restored-agent state. An invalidated fingerprint (an
    /// observed agent exit) clears instead of re-adopting, and a panel with no
    /// restored snapshot only adopts one while the agent is plausibly running
    /// there. Without that gate, a persist running after the user quit the
    /// agent would repaint the agent brand icon on a plain shell tab.
    func adoptIndexedRestorableAgentSnapshot(
        _ snapshot: SessionRestorableAgentSnapshot,
        panelId: UUID
    ) {
        let fingerprint = TabManager.restorableAgentSnapshotFingerprint(snapshot)
        guard invalidatedRestoredAgentFingerprintsByPanelId[panelId] != fingerprint else {
            clearRestoredAgentSnapshot(panelId: panelId)
            return
        }
        if restoredAgentSnapshotsByPanelId[panelId] == nil {
            guard !(agentPIDKeysByPanelId[panelId] ?? []).isEmpty
                || panelShellActivityStates[panelId] == .commandRunning else {
                return
            }
        }
        restoredAgentSnapshotsByPanelId[panelId] = snapshot
        if restoredAgentResumeStatesByPanelId[panelId] == nil {
            restoredAgentResumeStatesByPanelId[panelId] = restoredAgentResumeStateForAcceptedSnapshot(
                panelId: panelId
            )
        }
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        syncTerminalTabAgentIconAsset(forPanelId: panelId)
    }

    func restoredAgentResumeStateForAcceptedSnapshot(panelId: UUID) -> RestoredAgentResumeState {
        panelShellActivityStates[panelId] == .commandRunning
            ? .observedAgentCommandRunning
            : .manualResumeAvailable
    }

    /// A stale-agent prune proved that an agent process recorded for this
    /// panel died, so the panel's restorable snapshot no longer describes a
    /// running session: invalidate it and return the tab to the plain terminal
    /// icon, exactly as the shell-activity machine does when it observes the
    /// exit. A queued auto-resume and a hibernated panel keep their snapshot
    /// (their recorded runtime describes a previous run, not the pending
    /// resume), and remote workspaces are skipped because local process
    /// liveness proves nothing about a remote agent.
    func invalidateRestoredAgentSnapshotForProvenAgentExit(panelId: UUID) {
        guard !isRemoteWorkspace,
              let snapshot = restoredAgentSnapshotsByPanelId[panelId],
              restoredAgentResumeStatesByPanelId[panelId] != .awaitingAutoResumeCommand,
              (panels[panelId] as? TerminalPanel)?.isAgentHibernated != true else {
            return
        }
        invalidateRestoredAgentSnapshot(panelId: panelId, restoredAgent: snapshot)
    }
}
