import Foundation

/// Describes a machine-readable capability limitation reason.
public enum CapabilityReason: Hashable, Sendable {
    /// Hooks have not yet contributed evidence for this session.
    case hooksNotObserved
    /// Hooks are unavailable because the agent or user configuration disables them.
    case hooksUnavailableSafeMode
    /// The session launched while the cmux socket was unavailable.
    case launchedWhileSocketDown
    /// The observed CLI version is below a required minimum.
    case cliVersionBelowMinimum(found: String, minimum: String)
    /// The transcript could not be read by the adapter.
    case transcriptNotReadable
    /// Multiple evidence channels disagreed about the same session identity.
    case evidenceConflict

    /// The localization key that callers can map to user-facing help text.
    public var localizationKey: String {
        switch self {
        case .hooksNotObserved: "agent.capability.hooksNotObserved"
        case .hooksUnavailableSafeMode: "agent.capability.hooksUnavailableSafeMode"
        case .launchedWhileSocketDown: "agent.capability.launchedWhileSocketDown"
        case .cliVersionBelowMinimum: "agent.capability.cliVersionBelowMinimum"
        case .transcriptNotReadable: "agent.capability.transcriptNotReadable"
        case .evidenceConflict: "agent.capability.evidenceConflict"
        }
    }
}
