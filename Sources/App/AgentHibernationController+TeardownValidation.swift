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
        return (shouldProceed?() ?? true) &&
            AgentHibernationTrackingGate.isEnabled() &&
            record.isStillOwnedByOriginalWorkspace &&
            (
                request.trigger == .systemMemoryPressure ||
                    !index.hasLiveProcess(
                        workspaceId: record.key.workspaceId,
                        panelId: record.key.panelId
                    )
            ) &&
            index.processIDs(
                workspaceId: record.key.workspaceId,
                panelId: record.key.panelId
            ) == record.processIDs &&
            index.processIdentities(
                workspaceId: record.key.workspaceId,
                panelId: record.key.panelId
            ) == record.processIdentities &&
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
