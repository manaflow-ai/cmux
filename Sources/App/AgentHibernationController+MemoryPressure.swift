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
        isPressureStillCritical: @escaping @MainActor () -> Bool,
        onHibernationCompleted: @escaping @MainActor (Int) -> Void
    ) -> Bool {
        guard memoryPressureEvaluation == nil,
              isPressureStillCritical() else {
            return false
        }

        let requestID = UUID()
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
            guard !Task.isCancelled,
                  isPressureStillCritical() else {
                return
            }
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
            guard isPressureStillCritical() else { return }
            let confirmationIndex = await RestorableAgentSessionIndex
                .loadIncludingProcessDetectedSnapshots()
            guard !Task.isCancelled,
                  isPressureStillCritical() else {
                return
            }
            let confirmationEvaluation = self.evaluate(
                index: confirmationIndex,
                settings: AgentHibernationSettings.values(),
                now: .now,
                trigger: .systemMemoryPressure,
                teardownShouldProceed: isPressureStillCritical,
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
    }
}
