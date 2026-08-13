import Foundation

/// Authoritative lifecycle state for one coding-agent feed item.
public enum MobileWorkstreamFeedStatus: Equatable, Sendable {
    case pending
    case resolved(decision: MobileWorkstreamDecision?)
    case expired
    case telemetry
    case unknown(String)

    /// Whether the item still blocks an agent for user input.
    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

/// A resolved decision preserved for display and reconciliation.
public enum MobileWorkstreamDecision: Equatable, Sendable {
    case permission(mode: String)
    case exitPlan(mode: String, feedback: String?)
    case question(selections: [String])
    case form(action: String, selections: [String])
    case unknown(kind: String)
}
