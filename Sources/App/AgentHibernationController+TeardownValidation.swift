import Foundation

extension AgentHibernationController {
    func teardownIsStillSafe(
        _ request: ConfirmedTeardownRequest,
        index: RestorableAgentSessionIndex,
        shouldProceed: (@MainActor () -> Bool)?
    ) -> Bool {
        let record = request.record
        let currentAgent = record.workspace.restorableAgentForHibernation(
            panelId: record.key.panelId,
            index: index
        )
        let currentLifecycle = postSnapshotLifecycle(for: record, index: index)
        let currentEffectiveLastActivityAt = postSnapshotEffectiveLastActivityAt(
            for: record,
            index: index
        )
        let currentProcessEntry = index.entry(
            workspaceId: record.key.workspaceId,
            panelId: record.key.panelId
        )
        let currentHibernationPanelProcessIDs =
            currentProcessEntry?.hibernationPanelProcessIDs ?? []
        let currentTerminationProcessIDs = currentProcessEntry?.terminationProcessIDs ?? []
        let currentTerminationProcessIdentities =
            currentProcessEntry?.terminationProcessIdentities ?? [:]
        // Routine reclaim may terminate a live agent only when the fresh index
        // still proves the same exclusive, identity-complete process scope.
        return (shouldProceed?() ?? true) &&
            AgentHibernationTrackingGate.isEnabled() &&
            record.isStillOwnedByOriginalWorkspace &&
            (
                request.trigger == .systemMemoryPressure ||
                    currentProcessEntry?.processSafetyAllowsScheduledHibernation ?? true
            ) &&
            (
                request.trigger != .systemMemoryPressure ||
                    currentProcessEntry?.containsUnrelatedProcess != true
            ) &&
            currentHibernationPanelProcessIDs == record.panelProcessIDs &&
            currentTerminationProcessIDs == record.processIDs &&
            currentTerminationProcessIdentities == record.processIdentities &&
            TabManager.restorableAgentSnapshotFingerprint(currentAgent) ==
                TabManager.restorableAgentSnapshotFingerprint(record.agent) &&
            !record.terminalPanel.isAgentHibernated &&
            record.terminalPanel.surface.hasLiveSurface &&
            AppDelegate.shared?.agentHibernationPanelIsProtected(
                workspace: record.workspace,
                panelId: record.key.panelId
            ) == false &&
            currentLifecycle.allowsHibernation &&
            (terminalInputByPanel[record.key] ?? 0) <=
                (lifecycleChangeByPanel[record.key] ?? 0) &&
            teardownValidationGeneration == request.generation &&
            (teardownValidationEpochByPanel[record.key] ?? 0) == request.epoch &&
            hibernationFingerprint(for: record) == request.confirmationFingerprint &&
            currentEffectiveLastActivityAt <= request.effectiveLastActivityAt
    }
}
