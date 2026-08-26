/// Admission state for the single readiness delivery owned by a PTY lifecycle.
public enum RemotePTYLifecycleReadinessDeliveryAdmission: Sendable, Equatable {
    /// The caller acquired the lifecycle's readiness delivery.
    case acquired
    /// Another caller currently owns the readiness delivery.
    case inFlight
    /// Readiness was already committed for this lifecycle.
    case alreadyCompleted
    /// The lifecycle is no longer current.
    case stale
}
