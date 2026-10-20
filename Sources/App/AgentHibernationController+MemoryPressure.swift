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
        guard isPressureStillCritical() else {
            clearMemoryPressureConfirmations()
            return false
        }
        guard memoryPressureEvaluation == nil else {
            return false
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var awaitsTeardownCompletion = false
            var preserveConfirmations = false
            defer {
                if !awaitsTeardownCompletion {
                    self.finishMemoryPressureEvaluation(
                        requestID: requestID,
                        clearConfirmations: !preserveConfirmations
                    )
                }
            }

            let settings = AgentHibernationSettings.values()
            let index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
            guard !Task.isCancelled,
                  isPressureStillCritical() else {
                return
            }
            let evaluation = self.evaluate(
                index: index,
                settings: settings,
                now: now,
                trigger: .systemMemoryPressure,
                teardownShouldProceed: isPressureStillCritical,
                onHibernationCompleted: { [weak self] hibernatedCount in
                    self?.finishMemoryPressureEvaluation(requestID: requestID)
                    onHibernationCompleted(hibernatedCount)
                }
            )
            preserveConfirmations = evaluation.hasCandidates
            awaitsTeardownCompletion = evaluation.beganTeardowns
        }
        memoryPressureEvaluation = (requestID, task)
        return true
    }

    /// Evaluates aggregate pressure through the existing confirmation state.
    ///
    /// Aggregate samples arrive periodically, so this method performs one
    /// fresh evaluation and returns. The next sample advances any pending
    /// confirmation; no timer or sleep coordinates this path. Aggregate
    /// pressure is only a trigger and never a quota on memory, agents, panes,
    /// or child processes.
    @discardableResult
    func reclaimIdleAgentsForMemoryPressure(
        now: Date,
        isPressureStillActive: @escaping @MainActor () -> Bool,
        onHibernationCompleted: @escaping @MainActor (Int) -> Void
    ) -> Bool {
        guard isPressureStillActive() else {
            clearAggregateMemoryPressureConfirmations()
            return false
        }
        guard memoryPressureEvaluation == nil else {
            return false
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var awaitsTeardownCompletion = false
            var preserveConfirmations = false
            defer {
                if !awaitsTeardownCompletion {
                    self.finishMemoryPressureEvaluation(
                        requestID: requestID,
                        clearConfirmations: !preserveConfirmations
                    )
                }
            }

            let index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
            guard !Task.isCancelled,
                  isPressureStillActive() else {
                return
            }
            let evaluation = self.evaluate(
                index: index,
                settings: AgentHibernationSettings.values(),
                now: now,
                trigger: .aggregateMemoryPressure,
                teardownShouldProceed: isPressureStillActive,
                onHibernationCompleted: { [weak self] hibernatedCount in
                    self?.finishMemoryPressureEvaluation(
                        requestID: requestID,
                        clearConfirmations: false
                    )
                    self?.clearAggregateMemoryPressureConfirmations()
                    onHibernationCompleted(hibernatedCount)
                }
            )
            preserveConfirmations = evaluation.hasCandidates
            awaitsTeardownCompletion = evaluation.beganTeardowns
        }
        memoryPressureEvaluation = (requestID, task)
        return true
    }

    private func finishMemoryPressureEvaluation(
        requestID: UUID,
        clearConfirmations: Bool = true
    ) {
        guard memoryPressureEvaluation?.id == requestID else { return }
        memoryPressureEvaluation = nil
        if clearConfirmations {
            clearMemoryPressureConfirmations()
        }
    }
}
