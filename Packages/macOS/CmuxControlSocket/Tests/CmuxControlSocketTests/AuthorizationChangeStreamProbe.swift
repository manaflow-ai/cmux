/// Observes when a test-only authorization-change stream requests its next element.
actor AuthorizationChangeStreamProbe {
    private var requestCount = 0
    private var requestWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var nextContinuation: CheckedContinuation<Void?, Never>?

    func next() async -> Void? {
        requestCount += 1
        let readyTargets = requestWaiters.keys.filter { $0 <= requestCount }
        let readyWaiters = readyTargets.flatMap {
            requestWaiters.removeValue(forKey: $0) ?? []
        }
        readyWaiters.forEach { $0.resume() }

        return await withCheckedContinuation { continuation in
            precondition(nextContinuation == nil)
            nextContinuation = continuation
        }
    }

    func signalAndWaitUntilConsumed() async {
        await waitForRequestCount(1)
        let nextRequestCount = requestCount + 1
        guard let nextContinuation else {
            preconditionFailure("Authorization change stream was not awaiting its next element")
        }
        self.nextContinuation = nil
        nextContinuation.resume(returning: ())
        await waitForRequestCount(nextRequestCount)
    }

    func waitForRequestCount(_ target: Int) async {
        guard requestCount < target else { return }
        await withCheckedContinuation { continuation in
            requestWaiters[target, default: []].append(continuation)
        }
    }

    nonisolated func finish() {
        Task { await finishPendingNext() }
    }

    private func finishPendingNext() {
        let continuation = nextContinuation
        nextContinuation = nil
        continuation?.resume(returning: nil)
    }
}
