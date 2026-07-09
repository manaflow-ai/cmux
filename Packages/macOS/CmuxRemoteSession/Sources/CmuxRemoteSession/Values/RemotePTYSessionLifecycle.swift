/// The session manager's authoritative lifecycle for one persistent remote PTY.
public enum RemotePTYSessionLifecycle: String, Sendable, Equatable {
    /// No explicit cleanup owns the session; transport loss remains retryable.
    case active
    /// An explicit cleanup is serialized on the coordinator queue but has not completed.
    case intentionalCleanupRequested = "intentional_cleanup_requested"
    /// Explicit cleanup succeeded; require-existing attachments must end instead of retrying.
    case intentionallyClosed = "intentionally_closed"
}
