/// The part of evaluation represented by a diagnostic trace entry.
public enum CmuxAgentTracePhase: String, Codable, Hashable, Sendable {
    /// Process identity matcher evaluation.
    case process
    /// Screen or OSC state-rule evaluation.
    case state
}
