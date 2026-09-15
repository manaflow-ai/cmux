actor IrxAsyncLatch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

enum IrxAsyncWait {
    static func until(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<20 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        struct TimedOut: Error {}
        throw TimedOut()
    }
}
