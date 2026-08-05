actor WatcherConstructionThreadProbe {
    private var observations: [Bool] = []
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func record(_ isMainThread: Bool) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: isMainThread)
        } else {
            observations.append(isMainThread)
        }
    }

    func next() async -> Bool {
        if let observation = observations.first {
            observations.removeFirst()
            return observation
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
