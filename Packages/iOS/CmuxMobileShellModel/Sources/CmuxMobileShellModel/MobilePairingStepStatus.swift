import Foundation

/// The current visible state of one pairing gate.
public enum MobilePairingStepStatus: Equatable, Sendable {
    /// The gate has not been reached for the current attempt.
    case pending
    /// The gate is currently being checked.
    case inProgress
    /// The gate completed successfully.
    case succeeded
    /// The gate failed and should show an actionable message.
    case failed
}
