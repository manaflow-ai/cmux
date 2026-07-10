import Foundation

/// Lifecycle rules for a panel's restored (resumable) agent snapshot.
///
/// The snapshot serves two roles with different lifetimes. As the *recorded
/// session* it must survive an agent exit: session persistence, manual resume
/// after relaunch, and conversation forking all rely on it (auto-resume is
/// separately suppressed via `wasAgentRunning`). As the *icon signal* it must
/// not survive an agent exit: a plain-shell tab with no live agent and no
/// pending restore shows the plain terminal icon (#7822), for every agent
/// kind. `RestoredAgentResumeState.recordedSessionOnly` carries that
/// distinction: it keeps the snapshot while telling the icon resolver the
/// agent is known not to be running here.
extension Workspace {
    /// Reconciles a persist-time indexed restorable-agent snapshot into the
    /// panel's in-memory restored-agent state. An invalidated fingerprint (an
    /// observed agent exit followed by a new foreground command) clears
    /// instead of re-adopting. A fresh adoption's resume state records
    /// whether the agent is plausibly the running foreground command; without
    /// that provenance, a persist running after the user quit the agent would
    /// repaint the agent brand icon on a plain shell tab.
    func adoptIndexedRestorableAgentSnapshot(
        _ snapshot: SessionRestorableAgentSnapshot,
        panelId: UUID
    ) {
        let fingerprint = TabManager.restorableAgentSnapshotFingerprint(snapshot)
        guard invalidatedRestoredAgentFingerprintsByPanelId[panelId] != fingerprint else {
            clearRestoredAgentSnapshot(panelId: panelId)
            return
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

    /// Adoption provenance: only a running foreground command makes the
    /// adopted session an "observed running agent". Anything else — an idle
    /// prompt after the user quit the agent, or an unknown shell state — is a
    /// recorded session whose icon relevance is owned by live agent runtime,
    /// not by this snapshot. Seeded restore paths assign
    /// `.manualResumeAvailable` themselves and never come through here.
    func restoredAgentResumeStateForAcceptedSnapshot(panelId: UUID) -> RestoredAgentResumeState {
        panelShellActivityStates[panelId] == .commandRunning
            ? .observedAgentCommandRunning
            : .recordedSessionOnly
    }

    /// A stale-agent prune proved that an agent process recorded for this
    /// panel died, so the panel's restorable snapshot no longer describes a
    /// running session: downgrade it to `.recordedSessionOnly` so the tab
    /// returns to the plain terminal icon while the session stays recorded
    /// for manual resume, relaunch persistence, and forking. Pending
    /// auto-resume states keep their snapshot untouched (their recorded
    /// runtime describes a previous run, not the pending resume), hibernated
    /// panels keep their deliberate brand mark, and remote workspaces are
    /// skipped because local process liveness proves nothing about a remote
    /// agent.
    func downgradeRestoredAgentSnapshotForProvenAgentExit(panelId: UUID) {
        guard !isRemoteWorkspace,
              restoredAgentSnapshotsByPanelId[panelId] != nil,
              (panels[panelId] as? TerminalPanel)?.isAgentHibernated != true else {
            return
        }
        switch restoredAgentResumeStatesByPanelId[panelId] {
        case .some(.awaitingAutoResumeCommand), .some(.autoResumeCommandRunning),
             .some(.recordedSessionOnly):
            return
        case .some(.manualResumeAvailable), .some(.observedAgentCommandRunning), nil:
            restoredAgentResumeStatesByPanelId[panelId] = .recordedSessionOnly
            syncTerminalTabAgentIconAsset(forPanelId: panelId)
        }
    }
}
