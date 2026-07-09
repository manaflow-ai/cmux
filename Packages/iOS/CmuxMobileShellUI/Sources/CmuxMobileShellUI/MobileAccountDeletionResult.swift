/// Result of an authenticated mobile account deletion request.
public enum MobileAccountDeletionResult: Equatable, Sendable {
    /// The server accepted the deletion request, but background cleanup is still running.
    case accepted(MobileAccountDeletionStatus)

    /// The server reports that account deletion has completed.
    case completed
}
