/// Wire names for Fleet task states.
///
/// The raw values are the snake_case strings used by the control socket.
public enum ControlFleetTaskStateName: String, CaseIterable, Sendable, Equatable {
    /// The task is queued and has not started.
    case queued
    /// The task is provisioning its execution environment.
    case provisioning
    /// The task is launching its agent process.
    case launching
    /// The task is currently running.
    case running
    /// The task is waiting for user or operator input.
    case needsInput = "needs_input"
    /// The task is stalled and needs attention.
    case stalled
    /// The task is waiting before an automatic retry.
    case retryBackoff = "retry_backoff"
    /// The task is waiting for review.
    case awaitingReview = "awaiting_review"
    /// The task completed successfully.
    case done
    /// The task failed.
    case failed
    /// The task was cancelled.
    case cancelled
}
