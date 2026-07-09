/// Durable server-side state for a mobile account deletion request.
public enum MobileAccountDeletionStatus: String, Decodable, Equatable, Sendable {
    /// Cleanup is queued and has not started.
    case pending

    /// Cleanup has been claimed by a worker.
    case inProgress = "in_progress"

    /// cmux cleanup finished and Stack account deletion is queued.
    case stackDeletePending = "stack_delete_pending"

    /// Stack account deletion is running.
    case stackDeleteInProgress = "stack_delete_in_progress"

    /// The account deletion workflow completed.
    case completed

    /// The deletion request failed and must be retried.
    case failed
}
