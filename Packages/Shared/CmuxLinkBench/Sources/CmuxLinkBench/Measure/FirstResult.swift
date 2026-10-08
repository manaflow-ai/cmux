/// The first resolution wins.
actor FirstResult<T: Sendable> {
    private var result: Result<T, any Error>?
    private var waiters: [UInt64: CheckedContinuation<T, any Error>] = [:]
    private var nextWaiterID: UInt64 = 0

    func resolve(_ outcome: Result<T, any Error>) {
        guard result == nil else { return }
        result = outcome
        for waiter in waiters.values { waiter.resume(with: outcome) }
        waiters = [:]
    }

    func value() async throws -> T {
        let waiterID = nextWaiterID
        nextWaiterID &+= 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    private func cancel(waiterID: UInt64) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
    }
}
