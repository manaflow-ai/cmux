internal import Foundation

/// Completes asynchronous teardown after every registered dispatch source has
/// run its cancellation handler.
final class DispatchSourceCancellationBarrier: @unchecked Sendable {
    // Lock carve-out: register() runs synchronously before source activation,
    // while DispatchSource cancellation callbacks synchronously call complete().
    // Moving these updates into unstructured actor Tasks could reorder register
    // and complete relative to wait(), letting teardown observe zero too early.
    // This lock protects only the count and continuation handoff, never I/O or
    // an await. Every continuation is removed under the lock and resumed after
    // unlocking; all mutable state is locked, which justifies Sendable above.
    let lock = NSLock()
    /// The source-of-truth count; readers must hold ``lock``.
    internal private(set) var registrations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    deinit {}

    /// Registers one source before it is activated.
    func register() {
        lock.lock()
        registrations += 1
        lock.unlock()
    }

    /// Marks one source's cancellation handler complete.
    func complete() {
        lock.lock()
        registrations -= 1
        let waiters = registrations == 0 ? self.waiters : []
        if registrations == 0 {
            self.waiters.removeAll(keepingCapacity: false)
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Suspends without blocking an executor until all sources have cancelled.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard registrations > 0 else {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
