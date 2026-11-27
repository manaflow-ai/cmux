/// The recovery step the listener should take after an `accept(2)` failure.
///
/// Produced by ``SocketListenerPolicy/acceptFailureRecoveryAction(errnoCode:consecutiveFailures:)``.
public enum AcceptFailureRecoveryAction: Equatable, Sendable {
    /// Retry the accept with no delay (transient per-connection error).
    case retryImmediately
    /// Pause the accept source for `delayMs`, then resume on the same listener.
    case resumeAfterDelay(delayMs: Int)
    /// Tear the listener down and rebuild it after `delayMs` (fatal descriptor
    /// error or persistent failure streak).
    case rearmAfterDelay(delayMs: Int)

    /// The delay in milliseconds before the action runs (0 for immediate retry).
    public var delayMs: Int {
        switch self {
        case .retryImmediately:
            return 0
        case .resumeAfterDelay(let delayMs), .rearmAfterDelay(let delayMs):
            return delayMs
        }
    }

    /// A stable identifier recorded in telemetry breadcrumbs.
    public var debugLabel: String {
        switch self {
        case .retryImmediately:
            return "retry_immediately"
        case .resumeAfterDelay:
            return "resume_after_delay"
        case .rearmAfterDelay:
            return "rearm_after_delay"
        }
    }
}
