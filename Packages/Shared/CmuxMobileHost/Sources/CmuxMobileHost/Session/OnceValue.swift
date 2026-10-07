/// Holds the first value settled; `value()` waits for it. A request raced
/// against a deadline settles here, so the caller never waits for the loser:
/// in a task group the group itself would wait for a branch that ignores
/// cancellation, and the deadline would become a hang.
actor OnceValue<Value: Sendable> {
    private var settled: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func settle(_ value: Value) {
        guard settled == nil else { return }
        settled = value
        for waiter in waiters { waiter.resume(returning: value) }
        waiters.removeAll()
    }

    func value() async -> Value {
        if let settled { return settled }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
