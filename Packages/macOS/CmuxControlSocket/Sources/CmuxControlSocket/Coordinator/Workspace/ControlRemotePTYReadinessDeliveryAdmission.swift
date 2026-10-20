/// Admission state for one persistent PTY readiness delivery.
public enum ControlRemotePTYReadinessDeliveryAdmission: Sendable, Equatable {
    /// This caller owns the only readiness mutation allowed to enter the main actor.
    case acquired
    /// Another caller is already waiting to perform the readiness mutation.
    case inFlight
    /// An earlier caller completed the readiness mutation successfully.
    case alreadyCompleted
    /// The broker lifecycle was invalidated before this caller could claim it.
    case stale
}
