import Foundation

extension AgentHibernationController {
    final class CommittedTerminationObservation {
        let requestID: UUID
        let processExitCompletion: AgentHibernationProcessExitCompletion
        var task: Task<Void, Never>?
        var retryRecovery: (@MainActor () -> Void)?

        init(
            requestID: UUID,
            processExitCompletion: AgentHibernationProcessExitCompletion
        ) {
            self.requestID = requestID
            self.processExitCompletion = processExitCompletion
        }
    }

    @discardableResult
    func registerCommittedTerminationObservation(
        panelID: UUID,
        requestID: UUID = UUID(),
        processExitCompletion: AgentHibernationProcessExitCompletion
    ) -> UUID {
        if let current = committedTerminationObservationsByPanelID[panelID],
           current.requestID == requestID {
            return requestID
        }
        committedTerminationCleanupByPanelID
            .removeValue(forKey: panelID)?
            .task
            .cancel()
        if let previous = committedTerminationObservationsByPanelID.removeValue(
            forKey: panelID
        ) {
            previous.task?.cancel()
            if previous.processExitCompletion !== processExitCompletion {
                Task {
                    await previous.processExitCompletion.finish(false)
                }
            }
        }
        committedTerminationObservationsByPanelID[panelID] =
            CommittedTerminationObservation(
                requestID: requestID,
                processExitCompletion: processExitCompletion
            )
        return requestID
    }

    @discardableResult
    func replaceCommittedTerminationTask(
        panelID: UUID,
        requestID: UUID,
        with task: Task<Void, Never>
    ) -> Bool {
        guard let observation = committedTerminationObservationsByPanelID[panelID],
              observation.requestID == requestID else {
            task.cancel()
            return false
        }
        let previousTask = observation.task
        observation.task = task
        previousTask?.cancel()
        return true
    }

    func removeCommittedTerminationObservation(
        panelID: UUID,
        requestID: UUID
    ) {
        guard committedTerminationObservationsByPanelID[panelID]?.requestID == requestID,
              let observation = committedTerminationObservationsByPanelID.removeValue(
                  forKey: panelID
              ) else {
            return
        }
        observation.task?.cancel()
        committedTerminationCleanupByPanelID.removeValue(forKey: panelID)?.task.cancel()
    }
}
