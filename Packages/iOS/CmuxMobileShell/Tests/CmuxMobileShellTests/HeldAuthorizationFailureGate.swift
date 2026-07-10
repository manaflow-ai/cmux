actor HeldAuthorizationFailureGate {
    private var didReachHeldRequest = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReached() async {
        if didReachHeldRequest { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func holdUntilReleased() async {
        didReachHeldRequest = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
