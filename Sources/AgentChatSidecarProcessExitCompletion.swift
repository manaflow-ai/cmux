import Foundation

/// Delivers one cancellation-aware result for a sidecar root-process exit.
/// The process source callback finishes this actor; termination callers can
/// await it without polling the process table or blocking a cooperative
/// executor thread.
actor AgentChatSidecarProcessExitCompletion {
    private var result: Bool?
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Waits for the process-source result, returning false when cancelled.
    func wait() async -> Bool {
        if let result { return result }
        if Task.isCancelled { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters[waiterID] = continuation
                    // Cancellation can arrive between the check above and
                    // registration. Re-check after insertion so that race
                    // cannot leave a waiter suspended forever.
                    if Task.isCancelled {
                        waiters.removeValue(forKey: waiterID)?.resume(returning: false)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.cancel(waiterID: waiterID)
            }
        }
    }

    /// Publishes the first terminal result and resumes all current waiters.
    func finish(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        let pendingWaiters = waiters.values
        waiters.removeAll(keepingCapacity: false)
        for waiter in pendingWaiters {
            waiter.resume(returning: result)
        }
    }

    /// Cancels one waiter without changing the shared terminal result.
    private func cancel(waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }
}
