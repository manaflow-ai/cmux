internal import CmuxSocketControl
public import Darwin

/// Pure decision logic for the control-socket listener: accept-failure
/// recovery, socket-path unlink rules, and bind-failure path fallback.
///
/// Performs no I/O. Construct once at the composition root and inject; the
/// thresholds are configurable for tests.
///
/// ```swift
/// let policy = SocketListenerPolicy()
/// switch policy.acceptFailureRecoveryAction(errnoCode: errno, consecutiveFailures: failures) {
/// case .retryImmediately: ...
/// case .resumeAfterDelay(let delayMs): ...
/// case .rearmAfterDelay(let delayMs): ...
/// }
/// ```
public struct SocketListenerPolicy: Sendable {
    /// First-failure backoff in milliseconds; doubles per consecutive failure.
    public let acceptFailureBaseBackoffMs: Int
    /// Upper bound for the exponential backoff in milliseconds.
    public let acceptFailureMaxBackoffMs: Int
    /// Floor applied to rearm delays in milliseconds.
    public let acceptFailureMinimumRearmDelayMs: Int
    /// Consecutive-failure count at which the listener rearms instead of resuming.
    public let acceptFailureRearmThreshold: Int

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - acceptFailureBaseBackoffMs: First-failure backoff (default 10ms).
    ///   - acceptFailureMaxBackoffMs: Backoff cap (default 5s).
    ///   - acceptFailureMinimumRearmDelayMs: Rearm-delay floor (default 100ms).
    ///   - acceptFailureRearmThreshold: Failure streak that forces a rearm (default 50).
    public init(
        acceptFailureBaseBackoffMs: Int = 10,
        acceptFailureMaxBackoffMs: Int = 5_000,
        acceptFailureMinimumRearmDelayMs: Int = 100,
        acceptFailureRearmThreshold: Int = 50
    ) {
        self.acceptFailureBaseBackoffMs = acceptFailureBaseBackoffMs
        self.acceptFailureMaxBackoffMs = acceptFailureMaxBackoffMs
        self.acceptFailureMinimumRearmDelayMs = acceptFailureMinimumRearmDelayMs
        self.acceptFailureRearmThreshold = acceptFailureRearmThreshold
    }

    /// Classifies an `accept(2)` `errno` into a recovery class.
    ///
    /// - Parameter errnoCode: The `errno` from the failed `accept(2)`.
    /// - Returns: The ``SocketAcceptErrorClassification``.
    public func acceptErrorClassification(errnoCode: Int32) -> SocketAcceptErrorClassification {
        switch errnoCode {
        case EINTR, ECONNABORTED, EAGAIN, EWOULDBLOCK:
            return .immediateRetry
        case EMFILE, ENFILE, ENOBUFS, ENOMEM:
            return .resourcePressure
        case EBADF, EINVAL, ENOTSOCK:
            return .fatal
        default:
            return .retryWithBackoff
        }
    }

    /// Whether the accept error is fatal to the listener descriptor and
    /// requires a full rearm.
    ///
    /// - Parameter errnoCode: The `errno` from the failed `accept(2)`.
    public func shouldRearmListener(forAcceptErrnoCode errnoCode: Int32) -> Bool {
        acceptErrorClassification(errnoCode: errnoCode) == .fatal
    }

    /// Whether the accept error is transient and the accept should retry with
    /// no delay.
    ///
    /// - Parameter errnoCode: The `errno` from the failed `accept(2)`.
    public func shouldRetryAcceptImmediately(errnoCode: Int32) -> Bool {
        acceptErrorClassification(errnoCode: errnoCode) == .immediateRetry
    }

    /// Whether a consecutive-failure streak has crossed the rearm threshold.
    ///
    /// - Parameter consecutiveFailures: The current failure streak.
    public func shouldRearm(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= acceptFailureRearmThreshold
    }

    /// The exponential backoff for a consecutive-failure streak, capped at
    /// ``acceptFailureMaxBackoffMs`` (0 for no failures).
    ///
    /// - Parameter consecutiveFailures: The current failure streak.
    /// - Returns: The backoff in milliseconds.
    public func acceptFailureBackoffMilliseconds(consecutiveFailures: Int) -> Int {
        guard consecutiveFailures > 0 else { return 0 }
        var delay = acceptFailureBaseBackoffMs
        var remaining = consecutiveFailures - 1
        while remaining > 0 {
            if delay >= acceptFailureMaxBackoffMs {
                return acceptFailureMaxBackoffMs
            }
            delay = min(delay * 2, acceptFailureMaxBackoffMs)
            remaining -= 1
        }
        return delay
    }

    /// The backoff for a rearm, with the ``acceptFailureMinimumRearmDelayMs``
    /// floor applied.
    ///
    /// - Parameter consecutiveFailures: The current failure streak.
    /// - Returns: The rearm delay in milliseconds.
    public func acceptFailureRearmDelayMilliseconds(consecutiveFailures: Int) -> Int {
        max(
            acceptFailureBackoffMilliseconds(consecutiveFailures: consecutiveFailures),
            acceptFailureMinimumRearmDelayMs
        )
    }

    /// The recovery action for an accept failure: immediate retry for transient
    /// errors, a delayed rearm for fatal errors or persistent streaks, and a
    /// delayed resume otherwise.
    ///
    /// - Parameters:
    ///   - errnoCode: The `errno` from the failed `accept(2)`.
    ///   - consecutiveFailures: The current failure streak.
    /// - Returns: The ``AcceptFailureRecoveryAction`` to take.
    public func acceptFailureRecoveryAction(
        errnoCode: Int32,
        consecutiveFailures: Int
    ) -> AcceptFailureRecoveryAction {
        let classification = acceptErrorClassification(errnoCode: errnoCode)
        if classification == .immediateRetry {
            return .retryImmediately
        }

        if classification == .fatal
            || shouldRearm(consecutiveFailures: consecutiveFailures) {
            return .rearmAfterDelay(
                delayMs: acceptFailureRearmDelayMilliseconds(
                    consecutiveFailures: consecutiveFailures
                )
            )
        }

        return .resumeAfterDelay(
            delayMs: acceptFailureBackoffMilliseconds(
                consecutiveFailures: consecutiveFailures
            )
        )
    }

    /// Sampling rule for accept-failure telemetry breadcrumbs: the first three
    /// failures and every power-of-two milestone after that.
    ///
    /// - Parameter consecutiveFailures: The current failure streak.
    public func shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: Int) -> Bool {
        guard consecutiveFailures > 0 else { return false }
        if consecutiveFailures <= 3 {
            return true
        }
        return (consecutiveFailures & (consecutiveFailures - 1)) == 0
    }

    /// Whether accept-loop cleanup may unlink the socket path: only when the
    /// path still belongs to this listener, nothing is running or starting, and
    /// no newer accept-loop generation exists.
    ///
    /// - Parameters:
    ///   - pathMatches: Whether the listener's current path is the cleaned-up path.
    ///   - isRunning: Whether the listener believes it is running.
    ///   - activeGeneration: The active accept-loop generation (0 = none).
    ///   - listenerStartInProgress: Whether a new listener start is underway.
    public func shouldUnlinkSocketPathAfterAcceptLoopCleanup(
        pathMatches: Bool,
        isRunning: Bool,
        activeGeneration: UInt64,
        listenerStartInProgress: Bool
    ) -> Bool {
        guard pathMatches else { return false }
        guard !listenerStartInProgress else { return false }
        return !isRunning && activeGeneration == 0
    }

    /// Whether listener shutdown may unlink the socket path: only when the
    /// inode currently at the path is the one this listener bound.
    ///
    /// - Parameters:
    ///   - currentIdentity: The identity currently at the path.
    ///   - boundIdentity: The identity captured at bind time.
    public func shouldUnlinkSocketPathAfterListenerStop(
        currentIdentity: SocketPathIdentity?,
        boundIdentity: SocketPathIdentity?
    ) -> Bool {
        guard let currentIdentity, let boundIdentity else { return false }
        return currentIdentity == boundIdentity
    }

    /// The fallback socket path after a bind failure at the stable default
    /// path, or nil when no fallback applies.
    ///
    /// Only the shared stable default path falls back (to the user-scoped
    /// stable path) and only for permission/lock/occupancy failures another
    /// user's listener can cause. Tagged and explicit paths never fall back.
    ///
    /// - Parameters:
    ///   - requestedPath: The path the bind attempted.
    ///   - stage: The failing stage from ``SocketBindAttemptResult/failure(path:stage:errnoCode:)``
    ///     or ``SocketPathLockAcquisition/failed(_:)``.
    ///   - errnoCode: The failing `errno`.
    ///   - currentUserID: The uid used to derive the user-scoped path (defaults
    ///     to the current user; injectable for tests).
    public func fallbackSocketPathAfterBindFailure(
        requestedPath: String,
        stage: String,
        errnoCode: Int32,
        currentUserID: uid_t = getuid()
    ) -> String? {
        guard requestedPath == SocketControlSettings.stableDefaultSocketPath else {
            return nil
        }

        switch stage {
        case "unlink" where errnoCode == EACCES || errnoCode == EPERM:
            return SocketControlSettings.userScopedStableSocketPath(currentUserID: currentUserID)
        case "create_lock_directory", "open_lock", "lock":
            return SocketControlSettings.userScopedStableSocketPath(currentUserID: currentUserID)
        case "existing_path", "stat_existing_path":
            return SocketControlSettings.userScopedStableSocketPath(currentUserID: currentUserID)
        case "bind" where errnoCode == EACCES || errnoCode == EPERM || errnoCode == EADDRINUSE:
            return SocketControlSettings.userScopedStableSocketPath(currentUserID: currentUserID)
        default:
            return nil
        }
    }
}
