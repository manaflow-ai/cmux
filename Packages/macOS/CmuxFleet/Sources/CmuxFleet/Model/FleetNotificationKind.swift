/// Identifies the kind of notification Fleet wants the engine to post.
public enum FleetNotificationKind: String, CaseIterable, Codable, Sendable {
    /// The agent requested human input.
    case needsInput

    /// A retry was scheduled after a recoverable stop.
    case retryScheduled

    /// A pull request is ready for human review.
    case awaitingReview

    /// The task reached a terminal failure.
    case failed

    /// The task was cancelled.
    case cancelled
}
