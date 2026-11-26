internal import os

/// Atomically coalesces and validates one broker-owned PTY readiness generation.
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
    private enum ReadinessDeliveryState {
        case available
        case inFlight
        case completed
    }

    private struct State {
        var isCurrent = true
        var readinessDelivery = ReadinessDeliveryState.available
    }

    // Lock carve-out: readiness admission, one-way broker invalidation, and the
    // synchronous main-actor state commit need a non-suspending atomic boundary.
    // The closure is limited to bounded state writes and cannot call the broker
    // or publish callbacks.
    private let state = OSAllocatedUnfairLock(initialState: State())

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
        try state.withLockUnchecked { state in
            guard state.isCurrent else { return nil }
            return try operation()
        }
    }

    /// Claims the lifecycle's single worker-to-main readiness delivery.
    ///
    /// - Returns: The current admission state after the atomic claim attempt.
    public func beginReadinessDeliveryAdmission() -> RemotePTYLifecycleReadinessDeliveryAdmission {
        state.withLock { state in
            guard state.isCurrent else { return .stale }
            switch state.readinessDelivery {
            case .available:
                state.readinessDelivery = .inFlight
                return .acquired
            case .inFlight:
                return .inFlight
            case .completed:
                return .alreadyCompleted
            }
        }
    }

    /// Completes an acquired readiness delivery.
    ///
    /// - Parameter succeeded: Whether the main-actor readiness mutation applied.
    public func finishReadinessDeliveryAdmission(succeeded: Bool) {
        state.withLock { state in
            guard state.isCurrent, state.readinessDelivery == .inFlight else { return }
            state.readinessDelivery = succeeded ? .completed : .available
        }
    }

    /// Permanently prevents subsequent commits through this lease.
    func invalidate() {
        state.withLock { $0.isCurrent = false }
    }
}
