import CMUXAgentLaunch
import Foundation

/// `Workspace` is the live host for its `AgentHibernationCoordinator`. The
/// coordinator (in `CMUXAgentLaunch`) owns the agent lifecycle / hibernation /
/// resume-binding *orchestration*; the per-panel state it mutates lives in
/// `AgentHibernationLifecycleModel`. Everything else those bodies touch is
/// irreducibly app-coupled, so each member here reproduces one read or mutation
/// the legacy inline bodies performed on `self`: the live panel set and focus,
/// the live `TerminalPanel` hibernation entry/resume, the agent-pid reaping that
/// frees tracked ports, the `AgentHibernationController` notifications, the
/// snapshot fingerprint, the rendered-layout visibility, the DEBUG invalidation
/// log, and the two resume-binding guard predicates. The coordinator is held by
/// `Workspace` and references this host weakly, so there is no retain cycle.
///
/// This mirrors the sibling `Workspace+SurfaceLifecycleHosting.swift` /
/// `Workspace+SessionRestoreHosting.swift` pattern: the lifted coordinator's
/// live seam conformance lives in its own app-target file so `Workspace.swift`
/// drains the orchestration instead of trading it for inline seam glue.
extension Workspace: AgentHibernationHosting {
    // MARK: - Panel existence / focus

    func agentHibernationPanelExists(_ panelId: UUID) -> Bool {
        panels[panelId] != nil
    }

    func agentHibernationFocusedPanelId() -> UUID? {
        focusedPanelId
    }

    func agentHibernationFocusPanel(_ panelId: UUID) {
        focusPanel(panelId)
    }

    // MARK: - AgentHibernationController notifications

    func agentHibernationRecordLifecycleChange(panelId: UUID) {
        AgentHibernationController.shared.recordAgentLifecycleChange(
            workspaceId: id,
            panelId: panelId
        )
    }

    func agentHibernationRecordTerminalFocus(panelId: UUID) {
        AgentHibernationController.shared.recordTerminalFocus(workspaceId: id, panelId: panelId)
    }

    // MARK: - Snapshot fingerprint

    func agentHibernationSnapshotFingerprint(_ snapshot: SessionRestorableAgentSnapshot) -> Int {
        TabManager.restorableAgentSnapshotFingerprint(snapshot)
    }

    // MARK: - Live TerminalPanel hibernation

    func agentHibernationTerminalPanelCanEnterHibernation(panelId: UUID) -> Bool {
        guard let terminalPanel = panels[panelId] as? TerminalPanel else { return false }
        return !terminalPanel.isAgentHibernated
    }

    func agentHibernationEnterTerminalHibernation(
        panelId: UUID,
        agent: SessionRestorableAgentSnapshot,
        lastActivityAt: Date
    ) {
        guard let terminalPanel = panels[panelId] as? TerminalPanel else { return }
        terminalPanel.enterAgentHibernation(agent: agent, lastActivityAt: lastActivityAt)
    }

    func agentHibernationTerminalPanelIsHibernated(panelId: UUID) -> Bool {
        guard let terminalPanel = panels[panelId] as? TerminalPanel else { return false }
        return terminalPanel.isAgentHibernated
    }

    func agentHibernationPrepareTerminalResume(
        panelId: UUID
    ) -> (didResume: Bool, queuedStartupInput: Bool) {
        guard let terminalPanel = panels[panelId] as? TerminalPanel else {
            return (didResume: false, queuedStartupInput: false)
        }
        let preparation = terminalPanel.prepareAgentHibernationResume()
        return (didResume: preparation.didResume, queuedStartupInput: preparation.queuedStartupInput)
    }

    // MARK: - Tracked agent PIDs / ports

    func agentHibernationAgentPIDKeys(panelId: UUID) -> Set<String> {
        agentPIDKeysByPanelId[panelId] ?? []
    }

    func agentHibernationClearAgentPID(key: String, panelId: UUID) {
        _ = clearAgentPID(key: key, panelId: panelId, clearStatus: false, refreshPorts: false)
    }

    func agentHibernationRefreshTrackedAgentPorts() {
        refreshTrackedAgentPorts()
    }

    // MARK: - Surface resume binding validation

    func agentHibernationTerminalPanelExists(panelId: UUID) -> Bool {
        terminalPanel(for: panelId) != nil
    }

    // MARK: - Shell activity (resume-progression input)

    func agentHibernationPanelShellIsCommandRunning(panelId: UUID) -> Bool {
        panelShellActivityStates[panelId] == .commandRunning
    }

    // MARK: - Rendered-layout visibility

    func agentHibernationAutoResumePresentationIsVisible() -> Bool {
        agentHibernationAutoResumePresentationVisible
    }

    func agentHibernationRenderedVisiblePanelIds() -> Set<UUID> {
        renderedVisiblePanelIdsForCurrentLayout()
    }

    // MARK: - DEBUG invalidation log

    func agentHibernationLogInvalidation(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot
    ) {
#if DEBUG
        cmuxDebugLog(
            "session.restore.agent.invalidate panel=\(panelId.uuidString.prefix(5)) " +
            "kind=\(restoredAgent.kind.rawValue) session=\(restoredAgent.sessionId.prefix(8))"
        )
#endif
    }

    func agentHibernationResumeBindingMatchesAgentHook(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard let binding = surfaceResumeBindingsByPanelId[panelId],
              binding.source == "agent-hook" else {
            return false
        }
        let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return checkpointId == nil || checkpointId == restoredAgent.sessionId
    }

    func agentHibernationResumeBindingHasStartupInput(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        guard let startupInput = binding.startupInput else { return false }
        return !startupInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
