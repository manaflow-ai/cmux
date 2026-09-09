import Foundation

/// Keeps cancellation cleanup suspended until the test checks synchronous revocation.
actor HiveSessionTeardownGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    func wait() async {
        guard !isOpen else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                started.continuation.yield(())
            }
        } onCancel: {
            self.cancelled.continuation.yield(())
        }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
