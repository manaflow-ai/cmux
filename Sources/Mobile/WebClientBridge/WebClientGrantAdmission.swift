import os

/// A synchronous admission lease that serializes grant revocation with
/// registry insertion.
///
/// The admitted body runs while the lock is held, so revocation cannot
/// interleave between the validity check and the admitted mutation. Every
/// admitted body must therefore stay bounded and must not perform blocking
/// file or network I/O; the lock is non-reentrant and a concurrent
/// `invalidate()` waits for the body to finish.
final class WebClientGrantAdmission: @unchecked Sendable {
    // lint:allow lock - revocation must atomically exclude registry insertion
    private let state = OSAllocatedUnfairLock(initialState: true)

    /// Invalidates this lease; future insertions fail and a concurrent
    /// insertion either completes before invalidation or observes it.
    func invalidate() {
        state.withLock { isValid in
            isValid = false
        }
    }

    /// Runs one synchronous admitted operation while the lease remains valid.
    func withValidAdmission<T>(_ body: () -> T) -> T? {
        // withLockUnchecked is deliberate: callers return Foundation-shaped
        // values such as `V2CallResult` containing `Any`. The body is wholly
        // synchronous and executes under this lock, so no value crosses an
        // additional concurrency boundary while the critical section runs.
        state.withLockUnchecked { isValid in
            guard isValid else { return nil }
            return body()
        }
    }
}
