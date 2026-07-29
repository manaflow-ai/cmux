import Foundation

extension AgentHibernationController {
    enum EvaluationPhase {
        case idle
        case running(id: UUID, task: Task<Void, Never>)
    }

    var evaluationTask: Task<Void, Never>? {
        guard case let .running(_, task) = evaluationPhase else { return nil }
        return task
    }

    func scheduleEvaluation(now: Date) {
        startEvaluationIfIdle { [weak self] in
            guard let self,
                  AgentHibernationTrackingGate.isEnabled(),
                  let index = await SharedLiveAgentIndex.shared.indexRefreshingNow(),
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
        guard case .idle = evaluationPhase else { return false }
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.finishEvaluation(id: requestID)
        }
        evaluationPhase = .running(id: requestID, task: task)
        return true
    }

    func cancelEvaluation() {
        evaluationTask?.cancel()
        evaluationPhase = .idle
    }

    private func finishEvaluation(id: UUID) {
        guard case let .running(activeID, _) = evaluationPhase,
              activeID == id else {
            return
        }
        evaluationPhase = .idle
    }
}
