import os

/// A synchronous admission lease that serializes grant revocation with
/// registry insertion.
///
/// The lock is intentionally limited to a short compare-and-set-style
/// critical section: it never protects ongoing connection state or network I/O.
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

    /// Runs one registry insertion while the lease remains valid.
    func withValidAdmission<T>(_ body: () -> T) -> T? {
        state.withLock { isValid in
            guard isValid else { return nil }
            return body()
        }
    }
}
