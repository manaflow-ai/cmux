import Foundation

/// Classifies a `WorkstreamItem`. Actionable kinds enter the Feed. Telemetry
/// kinds can enrich nearby actionable context but are not retained.
public enum WorkstreamKind: String, Codable, Sendable, CaseIterable, Equatable {
    // Actionable — shown by default.
    case permissionRequest
    case exitPlan
    case question

    // Telemetry — transient context only.
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
