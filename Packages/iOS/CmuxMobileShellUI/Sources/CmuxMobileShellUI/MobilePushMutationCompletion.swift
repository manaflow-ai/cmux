import Foundation

/// Resolves the first terminal result of an app-lifetime push mutation.
actor MobilePushMutationCompletion {
    private var result: MobilePushMutationResult?
    private var waiters: [
        UUID: CheckedContinuation<MobilePushMutationResult, Never>
    ] = [:]

    func resolve(
        _ outcome: MobilePushMutationOutcome,
        succeeded: Bool = false
    ) {
        guard result == nil else { return }
        let resolved = MobilePushMutationResult(
            outcome: outcome,
            succeeded: succeeded
        )
        result = resolved
        let waiters = self.waiters.values
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: resolved)
        }
    }

    func wait() async -> MobilePushMutationResult {
        if let result { return result }
        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else if Task.isCancelled {
                    continuation.resume(returning: MobilePushMutationResult(
                        outcome: .cancelled,
                        succeeded: false
                    ))
                } else {
                    waiters[waiterID] = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        })
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else {
            return
        }
        waiter.resume(returning: MobilePushMutationResult(
            outcome: .cancelled,
            succeeded: false
        ))
    }
}
