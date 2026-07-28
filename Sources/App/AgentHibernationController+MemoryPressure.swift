import Foundation

extension AgentHibernationController {
    /// Starts one asynchronous critical-pressure evaluation.
    ///
    /// The existing hibernation lifecycle remains the sole teardown owner:
    /// pressure only changes which safe idle agents it selects. Transcript
    /// protection, confirmation, activity revalidation, and scoped process
    /// termination are unchanged.
    @discardableResult
    func reclaimIdleAgentsForSystemMemoryPressure(
        now: Date,
        onHibernationCompleted: @escaping @MainActor (Int) -> Void
    ) -> Bool {
        guard memoryPressureEvaluation == nil else { return false }

        let requestID = UUID()
        AgentHibernationTrackingGate.setEnabled(true)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var awaitsTeardownCompletion = false
            defer {
                if !awaitsTeardownCompletion {
                    self.finishMemoryPressureEvaluation(requestID: requestID)
                }
            }

            let settings = AgentHibernationSettings.values()
            let index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
            guard !Task.isCancelled else { return }
            let initialEvaluation = self.evaluate(
                index: index,
                settings: settings,
                now: now,
                trigger: .systemMemoryPressure
            )
            guard initialEvaluation.hasCandidates else { return }

            do {
                try await ContinuousClock().sleep(for: .seconds(settings.confirmationSeconds))
            } catch {
                return
            }
            let confirmationIndex = await RestorableAgentSessionIndex
                .loadIncludingProcessDetectedSnapshots()
            guard !Task.isCancelled else { return }
            let confirmationEvaluation = self.evaluate(
                index: confirmationIndex,
                settings: AgentHibernationSettings.values(),
                now: .now,
                trigger: .systemMemoryPressure,
                onHibernationCompleted: { [weak self] hibernatedCount in
                    self?.finishMemoryPressureEvaluation(requestID: requestID)
                    onHibernationCompleted(hibernatedCount)
                }
            )
            awaitsTeardownCompletion = confirmationEvaluation.beganTeardowns
        }
        memoryPressureEvaluation = (requestID, task)
        return true
    }

    private func finishMemoryPressureEvaluation(requestID: UUID) {
        guard memoryPressureEvaluation?.id == requestID else { return }
        memoryPressureEvaluation = nil
        clearMemoryPressureConfirmations()
        AgentHibernationTrackingGate.setEnabled(
            AgentHibernationSettings.isEnabled()
        )
    }
}
