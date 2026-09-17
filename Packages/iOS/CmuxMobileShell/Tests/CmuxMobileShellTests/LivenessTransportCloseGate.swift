actor LivenessTransportCloseGate {
    private var closeStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        closeStarted = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters = []
        guard !released else { return }
        await withCheckedContinuation {
            releaseWaiters.append($0)
        }
    }

    func waitUntilCloseStarted() async {
        if closeStarted { return }
        await withCheckedContinuation {
            startWaiters.append($0)
        }
    }

    func release() {
        released = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters = []
    }
}
