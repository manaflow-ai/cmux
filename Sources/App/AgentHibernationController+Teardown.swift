import Foundation

extension AgentHibernationController {
    /// Runs the transcript snapshot off the main actor, then resumes teardown on the
    /// main actor only if the pane still qualifies. The snapshot MUST complete before
    /// SIGTERM / pty-close can trigger Claude's interrupted-exit transcript rewrite,
    /// so the teardown is sequenced after it rather than racing it; the re-validation
    /// below covers disable/stop and anything else that changed during the brief I/O hop.
    func beginConfirmedTeardown(
        record: AgentHibernationRecord,
        confirmationFingerprint: String,
        effectiveLastActivityAt: TimeInterval
    ) {
        let agent = record.agent
        let epoch = teardownValidationEpochByPanel[record.key] ?? 0
        Task { @MainActor in
            let snapshotOutcome = await Task.detached(priority: .utility) {
                AgentHibernationTranscriptGuard.snapshotBeforeTeardown(agent: agent)
            }.value
            // Re-validate: the pane must still be exactly as confirmed. Any activity,
            // scrollback change, visibility/protection change, hibernation disable,
            // hibernation, or surface loss during the hop aborts; the regular 30s
            // tick will re-arm if still idle.
            // Live-process state is not re-scanned here: a full index reload costs
            // 350ms-1.8s; new agents bump lifecycle/input hooks checked below.
            guard AgentHibernationTrackingGate.isEnabled(),
                  !record.terminalPanel.isAgentHibernated,
                  record.terminalPanel.surface.hasLiveSurface,
                  AppDelegate.shared?.agentHibernationPanelIsProtected(
                      workspace: record.workspace,
                      panelId: record.key.panelId
                  ) == false,
                  record.workspace.agentHibernationLifecycleState(
                      panelId: record.key.panelId,
                      fallback: record.lifecycle
                  ).allowsHibernation,
                  (self.terminalInputByPanel[record.key] ?? 0) <=
                      (self.lifecycleChangeByPanel[record.key] ?? 0),
                  (self.teardownValidationEpochByPanel[record.key] ?? 0) == epoch,
                  let currentFingerprint = self.hibernationFingerprint(for: record),
                  currentFingerprint == confirmationFingerprint,
                  (self.activityByPanel[record.key] ?? 0) <= effectiveLastActivityAt else {
                return
            }

            let snapshot: AgentHibernationTranscriptGuard.TeardownTranscriptSnapshot?
            switch snapshotOutcome {
            case .snapshot(let value):
                snapshot = value
            case .nothingToProtect:
                snapshot = nil
            case .unableToProtect:
                // Forfeit hibernation rather than risk issue #6565 transcript loss.
                return
            }

            self.terminateScopedProcessesForHibernation(record: record)
            record.workspace.enterAgentHibernation(
                panelId: record.key.panelId,
                agent: record.agent,
                lastActivityAt: Date(timeIntervalSince1970: effectiveLastActivityAt)
            )
            guard let snapshot else { return }
            let processIDs = record.processIDs
            Task.detached(priority: .utility) {
                await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
                    snapshot: snapshot,
                    processIDs: processIDs
                )
            }
        }
    }
}
