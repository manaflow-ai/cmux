import Foundation

/// Resolves the first terminal result of an app-lifetime push mutation.
actor MobilePushMutationCompletion {
    enum Outcome: Sendable, Equatable {
        case completed
        case timedOut
    }

    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    func resolve(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }

    func wait() async -> Outcome {
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
