import Foundation

extension AgentChatSessionRegistry {
    func scheduleProcessExitRetry(sessionID: String, pid: Int, attempt: Int) {
        guard attempt <= 3 else { return }
        processExitRetryTasks[sessionID]?.task.cancel()
        let retryID = UUID()
        let task = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self,
                  self.processExitRetryTasks[sessionID]?.id == retryID,
                  let record = self.record(sessionID: sessionID),
                  record.pid == pid,
                  record.state != .ended else { return }
            self.processExitRetryTasks[sessionID] = nil
            self.handleProcessExit(sessionID: sessionID, pid: pid, retryAttempt: attempt)
        }
        processExitRetryTasks[sessionID] = (id: retryID, task: task)
    }
}
