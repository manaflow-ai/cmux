import Foundation

/// Resolves the first terminal result of an app-lifetime push mutation.
actor MobilePushMutationCompletion {
    private var result: MobilePushMutationResult?
    private var waiters: [CheckedContinuation<MobilePushMutationResult, Never>] = []

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
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: resolved)
        }
    }

    func wait() async -> MobilePushMutationResult {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
            }
        }
    }
}
