internal import os

/// Atomically validates one broker-owned PTY generation during readiness commit.
///
/// The broker invalidates the lease whenever the lifecycle is replaced,
/// acknowledged, ended, claimed, or removed with its transport. Callers must
/// perform only a bounded in-memory state mutation inside
/// ``commitIfCurrent(_:)``. Payload construction, broker calls, presentation,
/// and notifications must run after the method returns.
///
/// Thread safety relies on confining validity to the internal lock and running
/// caller operations synchronously without escaping their originating executor.
public final class RemotePTYLifecycleCommitLease: @unchecked Sendable {
    // Lock carve-out: one-way broker invalidation and the synchronous main-actor
    // state commit need a non-suspending atomic boundary. The closure is limited
    // to bounded state writes and cannot call the broker or publish callbacks.
    private let validity = OSAllocatedUnfairLock(initialState: true)

    /// Creates a current lifecycle commit lease.
    public init() {}

    /// Runs `operation` only while this lifecycle generation is still current.
    ///
    /// - Parameter operation: A short synchronous in-memory mutation.
    /// - Returns: The operation result, or `nil` after invalidation.
    public func commitIfCurrent<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result? {
        try withCurrentCommit(operation)
    }

    /// Runs `operation` only while this lifecycle generation is still current.
    ///
    /// This spelling is also the package-neutral adapter seam used by the app
    /// when conforming the lease to its control-socket protocol.
    ///
    /// - Parameter operation: A short synchronous in-memory mutation.
    /// - Returns: The operation result, or `nil` after invalidation.
    public func withCurrentCommit<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result? {
        // The closure and result do not cross an isolation boundary; the lock
        // only keeps the synchronous validity check atomic with the operation.
        try validity.withLockUnchecked { isCurrent in
            guard isCurrent else { return nil }
            return try operation()
        }
    }

    /// Permanently prevents subsequent commits through this lease.
    func invalidate() {
        validity.withLock { $0 = false }
    }
}
