actor TestSignal {
    private var pendingSignals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            pendingSignals += 1
        }
    }

    func wait() async {
        if pendingSignals > 0 {
            pendingSignals -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
