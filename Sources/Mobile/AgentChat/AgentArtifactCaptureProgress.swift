/// Result of one policy-bounded automatic artifact capture batch.
enum AgentArtifactCaptureProgress: Equatable, Sendable {
    /// Every candidate in the snapshot has reached a terminal outcome.
    case complete
    /// A policy boundary left more candidates ready for another bounded batch.
    case needsContinuation
    /// The store is temporarily leased by another local mutation.
    case retryableContention
    /// Cancellation or an external safety gate requires a later event to retry.
    case blocked
}
