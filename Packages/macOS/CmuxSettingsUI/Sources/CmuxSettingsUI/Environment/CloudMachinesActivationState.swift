import Foundation

/// The first-use Cloud Machines state exposed to Settings without importing the
/// app's activation coordinator.
public enum CloudMachinesActivationState: Equatable, Sendable {
    /// Cloud is available but has not completed first-use setup.
    case disabled
    /// The shared setup operation is currently running.
    case enabling
    /// Cloud setup completed and Cloud machines may be used.
    case enabled
    /// Setup failed for a recoverable account or service reason.
    case failed(CloudMachinesActivationFailure)
    /// The user cancelled setup before it completed.
    case cancelled
    /// Rollout or managed policy makes Cloud unavailable on this Mac.
    case unavailable

    /// Whether Cloud machine operations are ready for use.
    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }
}

/// A recoverable reason first-use Cloud setup can fail.
public enum CloudMachinesActivationFailure: Equatable, Sendable {
    /// The signed-in team needs a paid plan for Cloud machines.
    case requiresPro
    /// The account session is missing or expired.
    case signInRequired
    /// The Cloud service could not complete setup.
    case serviceUnavailable
}
