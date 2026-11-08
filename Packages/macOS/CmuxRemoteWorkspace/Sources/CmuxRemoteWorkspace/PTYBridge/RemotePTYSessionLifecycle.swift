/// The shared tunnel's lifecycle decision for one logical persistent-PTY attachment generation.
public enum RemotePTYSessionLifecycle: String, Sendable, Equatable {
    /// No explicit cleanup owns the generation; transport loss remains retryable.
    case active
    /// Explicit cleanup has gated new bridges but the daemon close has not completed.
    case intentionalCleanupRequested = "intentional_cleanup_requested"
    /// Explicit cleanup completed; stale bridge starts must terminate without retrying.
    case intentionallyClosed = "intentionally_closed"
}
