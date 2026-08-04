import Foundation

extension AgentHibernationController {
    func discardTrackingStateForClosedPanel(workspaceId: UUID, panelId: UUID) {
        limitCommittedTerminationObservationAfterPanelClose(panelID: panelId)
        let key = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: panelId)
        activityByPanel.removeValue(forKey: key)
        terminalInputByPanel.removeValue(forKey: key)
        lifecycleChangeByPanel.removeValue(forKey: key)
        teardownValidationEpochByPanel.removeValue(forKey: key)
        discardTransientTrackingState(for: key)
    }

    func transferTrackingStateForMovedPanel(
        panelId: UUID,
        from sourceWorkspaceId: UUID,
        to destinationWorkspaceId: UUID
    ) {
        guard sourceWorkspaceId != destinationWorkspaceId else { return }
        let sourceKey = AgentHibernationPanelKey(
            workspaceId: sourceWorkspaceId,
            panelId: panelId
        )
        let destinationKey = AgentHibernationPanelKey(
            workspaceId: destinationWorkspaceId,
            panelId: panelId
        )
        let hadTrackingState =
            activityByPanel[sourceKey] != nil ||
            terminalInputByPanel[sourceKey] != nil ||
            lifecycleChangeByPanel[sourceKey] != nil ||
            teardownValidationEpochByPanel[sourceKey] != nil ||
            activityByPanel[destinationKey] != nil ||
            terminalInputByPanel[destinationKey] != nil ||
            lifecycleChangeByPanel[destinationKey] != nil ||
            teardownValidationEpochByPanel[destinationKey] != nil

        transferTimestamp(&activityByPanel, from: sourceKey, to: destinationKey)
        transferTimestamp(&terminalInputByPanel, from: sourceKey, to: destinationKey)
        transferTimestamp(&lifecycleChangeByPanel, from: sourceKey, to: destinationKey)
        let sourceEpoch = teardownValidationEpochByPanel.removeValue(forKey: sourceKey)
        let destinationEpoch = teardownValidationEpochByPanel.removeValue(forKey: destinationKey)
        if hadTrackingState {
            teardownValidationEpochByPanel[destinationKey] =
                max(sourceEpoch ?? 0, destinationEpoch ?? 0) &+ 1
        }
        // Confirmation, fingerprints, and retries are ownership-specific. A move
        // preserves raw input/lifecycle safety but requires a fresh qualification.
        discardTransientTrackingState(for: sourceKey)
        discardTransientTrackingState(for: destinationKey)
    }

    func limitCommittedTerminationObservationAfterPanelClose(
        panelID: UUID,
        cleanupDelay: Duration = .seconds(30),
        sleepUntilDeadline: @escaping @Sendable (Duration) async -> Bool = { duration in
            do {
                try await ContinuousClock().sleep(for: duration)
                return true
            } catch {
                return false
            }
        }
    ) {
        guard let observation = committedTerminationObservationsByPanelID[panelID] else {
            return
        }
        let observationRequestID = observation.requestID
        committedTerminationCleanupByPanelID
            .removeValue(forKey: panelID)?
            .task
            .cancel()
        let cleanupID = UUID()
        let cleanupTask = Task { @MainActor [weak self] in
            let didReachDeadline = await sleepUntilDeadline(cleanupDelay)
            guard let self else { return }
            defer {
                if self.committedTerminationCleanupByPanelID[panelID]?.requestID ==
                    cleanupID {
                    self.committedTerminationCleanupByPanelID.removeValue(
                        forKey: panelID
                    )
                }
            }
            guard didReachDeadline,
                  !Task.isCancelled,
                  self.committedTerminationCleanupByPanelID[panelID]?.requestID ==
                    cleanupID,
                  self.committedTerminationObservationsByPanelID[panelID]?.requestID ==
                    observationRequestID,
                  let removed = self.committedTerminationObservationsByPanelID.removeValue(
                      forKey: panelID
                  ) else {
                return
            }
            removed.task?.cancel()
            await removed.processExitCompletion.finish(false)
        }
        committedTerminationCleanupByPanelID[panelID] = CommittedTerminationCleanup(
            requestID: cleanupID,
            task: cleanupTask
        )
    }

    private func transferTimestamp(
        _ timestamps: inout [AgentHibernationPanelKey: TimeInterval],
        from sourceKey: AgentHibernationPanelKey,
        to destinationKey: AgentHibernationPanelKey
    ) {
        guard let sourceTimestamp = timestamps.removeValue(forKey: sourceKey) else { return }
        timestamps[destinationKey] = max(sourceTimestamp, timestamps[destinationKey] ?? 0)
    }

    private func discardTransientTrackingState(for key: AgentHibernationPanelKey) {
        unableToProtectByPanel.removeValue(forKey: key)
        teardownInFlightByPanel.removeValue(forKey: key)
        confirmations.removeValue(forKey: key)
        tailFingerprintSamples.removeValue(forKey: key)
    }
}
