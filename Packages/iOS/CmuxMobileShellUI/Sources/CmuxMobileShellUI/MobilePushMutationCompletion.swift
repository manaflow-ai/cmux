import Foundation

/// Resolves the first terminal result of an app-lifetime push mutation.
actor MobilePushMutationCompletion {
    private var outcome: MobilePushMutationOutcome?
    private var waiters: [CheckedContinuation<MobilePushMutationOutcome, Never>] = []

    func resolve(_ outcome: MobilePushMutationOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }

    func wait() async -> MobilePushMutationOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                waiters.append(continuation)
            }
        }
    }
}
