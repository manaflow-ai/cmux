/// Strength of the evidence supporting a reconciled agent status.
enum AgentStatusConfidence: Int, Equatable, Sendable {
    case uncertain
    case inferred
    case confident
}
