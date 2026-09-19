import Foundation

extension AgentChatSessionRegistry {
    private func scheduleProcessExitRetry(sessionID: String, pid: Int, attempt: Int) {
        guard attempt <= 3 else { return }
        processExitRetryTasks[sessionID]?.cancel()
        processExitRetryTasks[sessionID] = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self,
                  let record = self.records[sessionID],
                  record.pid == pid,
                  record.state != .ended else { return }
            self.handleProcessExit(sessionID: sessionID, pid: pid, retryAttempt: attempt)
            self.processExitRetryTasks[sessionID] = nil
        }
    }
}
