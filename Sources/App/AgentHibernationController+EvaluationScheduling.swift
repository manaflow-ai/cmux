import Foundation

extension AgentHibernationController {
    func scheduleEvaluation(now: Date) {
        startEvaluationIfIdle { [weak self] in
            guard let self,
                  AgentHibernationTrackingGate.isEnabled(),
                  let index = await SharedLiveAgentIndex.shared.indexRefreshingIfNeeded(),
                  !Task.isCancelled,
                  AgentHibernationTrackingGate.isEnabled() else {
                return
            }
            let settings = AgentHibernationSettings.values()
            guard settings.enabled else { return }
            self.evaluate(index: index, settings: settings, now: now)
        }
    }

    @discardableResult
    func startEvaluationIfIdle(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Bool {
        guard evaluationTask == nil else { return false }
        let requestID = UUID()
        evaluationTaskID = requestID
        evaluationTask = Task { @MainActor [weak self] in
            await operation()
            guard let self, self.evaluationTaskID == requestID else { return }
            self.evaluationTask = nil
            self.evaluationTaskID = nil
        }
        return true
    }

    func cancelEvaluationTask() {
        evaluationTask?.cancel()
        evaluationTask = nil
        evaluationTaskID = nil
    }
}
