public import Foundation

/// The lifecycle action selected by the relay-credential autopilot.
public enum IrxRelayCredentialAutopilotFailureDisposition: Equatable, Sendable {
    /// The autopilot will sleep for the supplied delay before retrying.
    case retry(delay: TimeInterval)
    /// A non-fatal auxiliary operation failed; the endpoint remains live.
    case advisory
    /// The autopilot has stopped and requires lifecycle-owner action.
    case terminal(requiresReauthentication: Bool)
}
