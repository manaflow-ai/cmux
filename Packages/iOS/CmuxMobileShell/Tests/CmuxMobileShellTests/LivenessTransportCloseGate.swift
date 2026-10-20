actor LivenessTransportCloseGate {
    private var closeStarted = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        closeStarted = true
        guard !released else { return }
        await withCheckedContinuation {
            releaseWaiters.append($0)
        }
    }

    func waitUntilCloseStarted(
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !closeStarted, clock.now < deadline {
            await Task.yield()
        }
        return closeStarted
    }

    func release() {
        released = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters = []
    }
}
