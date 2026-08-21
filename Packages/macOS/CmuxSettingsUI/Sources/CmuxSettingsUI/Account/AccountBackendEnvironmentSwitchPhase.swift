import Foundation

/// Where the host's live backend-environment switch currently is.
///
/// A package-local mirror of the host's switch-transaction phase:
/// `CmuxSettingsUI` deliberately does not link the host's auth runtime, so
/// the host's ``AccountFlow`` implementation maps its own phase type to this
/// one. ``BackendEnvironmentCard`` replaces the picker with a progress row
/// during the transitional phases and shows an outcome note at ``finished(_:)``.
public enum AccountBackendEnvironmentSwitchPhase: Equatable, Sendable {
    /// No switch in progress; the picker is interactive.
    case idle
    /// Parking the old environment's session (its defaults still active):
    /// the session is kept on this device for the return switch.
    case parking
    /// Override committed; the host is rebuilding its auth stack for the
    /// new environment.
    case retargeting
    /// Rebuilt on the target; restoring its parked session and — for a
    /// gated target — waiting for an eligible sign-in.
    case establishing
    /// Undoing the switch: rebuilding the previous environment and
    /// restoring its parked session.
    case reverting
    /// Switch complete; the card shows the outcome note until the host
    /// flow's ``AccountFlow/resetBackendEnvironmentSwitchPhase()`` runs.
    case finished(AccountBackendEnvironmentSwitchOutcome)

    /// Whether a run is in flight (any phase between `idle` and `finished`).
    public var isInFlight: Bool {
        switch self {
        case .idle, .finished: return false
        case .parking, .retargeting, .establishing, .reverting: return true
        }
    }
}

/// How a completed switch ended.
public enum AccountBackendEnvironmentSwitchOutcome: Equatable, Sendable {
    /// The device is on the requested environment.
    case switched
    /// The device is back on the previous environment with its session
    /// restored.
    case reverted(AccountBackendEnvironmentSwitchRevertReason)
}

/// Why a switch ended back on the previous environment.
public enum AccountBackendEnvironmentSwitchRevertReason: Equatable, Sendable {
    /// The user cancelled the target's sign-in prompt.
    case signInCancelled
    /// The target's sign-in prompt failed (timeout, network, server).
    case signInFailed
    /// The sign-in completed but the account may not use the gated target.
    case notEligible
}
