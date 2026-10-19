actor IrxDeadlineGate {
    private var isOpen = false
    private var isFinished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        while !isOpen {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
    }

    func markFinished() {
        isFinished = true
        let waiters = finishWaiters
        finishWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilFinished() async {
        guard !isFinished else { return }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
    }
}
