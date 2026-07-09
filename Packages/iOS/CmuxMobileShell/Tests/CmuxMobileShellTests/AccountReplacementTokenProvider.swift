actor AccountReplacementTokenProvider {
    private var requestCount = 0
    private var requestCountWaiters: [(
        expected: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var releaseContinuations: [Int: CheckedContinuation<String, Never>] = [:]

    func token() async throws -> String {
        requestCount += 1
        let requestIndex = requestCount
        let readyWaiters = requestCountWaiters.filter { $0.expected <= requestCount }
        requestCountWaiters.removeAll { $0.expected <= requestCount }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        return await withCheckedContinuation { continuation in
            releaseContinuations[requestIndex] = continuation
        }
    }

    func waitUntilRequestCount(_ expected: Int) async {
        if requestCount >= expected { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append((expected, continuation))
        }
    }

    func currentRequestCount() -> Int {
        requestCount
    }

    func releaseRequest(_ requestIndex: Int, with token: String) {
        releaseContinuations.removeValue(forKey: requestIndex)?.resume(returning: token)
    }
}
