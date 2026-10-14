actor MobileTaskModelPrefetchStartProbe {
    private var hasStarted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !hasStarted else { return }
        hasStarted = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
