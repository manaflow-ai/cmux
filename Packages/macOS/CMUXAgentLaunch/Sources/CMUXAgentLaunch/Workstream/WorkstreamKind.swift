import Foundation

/// Classifies a `WorkstreamItem`. Actionable kinds are surfaced in the
/// default Feed view; telemetry kinds are stored but hidden behind the
/// "All" filter toggle.
public enum WorkstreamKind: String, Codable, Sendable, CaseIterable, Equatable {
    // Actionable — shown by default.
    case permissionRequest
    case exitPlan
    case question

    // Telemetry — stored, hidden by default.
    case toolUse
    case toolResult
    case userPrompt
    case assistantMessage
    case sessionStart
    case sessionEnd
    case stop
    case todos

    public var isActionable: Bool {
        switch self {
        case .permissionRequest, .exitPlan, .question:
            return true
        default:
            return false
        }
    }
}
