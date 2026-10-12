import Foundation

/// One process-exit result shared by the panel observation and transcript guard.
actor AgentHibernationProcessExitCompletion {
    private var result: Bool?
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

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
                }
            }
        } onCancel: {
            Task {
                await self.cancel(waiterID: waiterID)
            }
        }
    }

    func finish(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        let pendingWaiters = waiters.values
        waiters.removeAll(keepingCapacity: false)
        for waiter in pendingWaiters {
            waiter.resume(returning: result)
        }
    }

    private func cancel(waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }
}
