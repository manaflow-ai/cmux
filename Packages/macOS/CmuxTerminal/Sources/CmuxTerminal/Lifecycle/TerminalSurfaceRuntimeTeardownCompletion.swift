import Foundation

/// One native-free completion shared by the enqueueing surface and teardown worker.
actor TerminalSurfaceRuntimeTeardownCompletion {
    private var didFinish = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func wait() async -> Bool {
        if didFinish { return true }
        if Task.isCancelled { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if didFinish {
                    continuation.resume(returning: true)
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

    func finish() {
        guard !didFinish else { return }
        didFinish = true
        let pendingWaiters = waiters.values
        waiters.removeAll(keepingCapacity: false)
        for waiter in pendingWaiters {
            waiter.resume(returning: true)
        }
    }

    private func cancel(waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }
}
