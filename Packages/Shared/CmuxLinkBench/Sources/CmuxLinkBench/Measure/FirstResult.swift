/// The first resolution wins.
actor FirstResult<T: Sendable> {
    private var result: Result<T, any Error>?
    private var waiters: [CheckedContinuation<T, any Error>] = []

    func resolve(_ outcome: Result<T, any Error>) {
        guard result == nil else { return }
        result = outcome
        for waiter in waiters { waiter.resume(with: outcome) }
        waiters = []
    }

    func value() async throws -> T {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
}
