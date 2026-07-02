import Foundation

/// Async-safe one-shot release gate: `wait()` suspends until `release()` opens
/// it, after which all current and future waiters proceed. Tests use it to hold
/// a provider mid-flight so the gate's timeout and cancellation paths run while
/// the redemption is still in progress.
actor AsyncReleaseGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
