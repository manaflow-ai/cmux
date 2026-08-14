/// One bounded diagnostic step emitted by the rule engine.
public struct CmuxAgentRuleTrace: Codable, Equatable, Hashable, Sendable {
    /// Manifest whose rule produced this trace step.
    public let manifestID: String
    /// Whether this step evaluated process identity or terminal state.
    public let phase: CmuxAgentTracePhase
    /// The manifest-authored matcher or state-rule identifier.
    public let ruleID: String
    /// Whether the rule matched the supplied snapshot.
    public let matched: Bool
    /// An optional condition index describing the successful condition.
    public let conditionID: String?
    /// A stable machine-readable explanation code for the evaluation.
    public let detail: String

    /// Creates a trace entry.
    public init(
        manifestID: String,
        phase: CmuxAgentTracePhase,
        ruleID: String,
        matched: Bool,
        conditionID: String? = nil,
        detail: String
    ) {
        self.manifestID = manifestID
        self.phase = phase
        self.ruleID = ruleID
        self.matched = matched
        self.conditionID = conditionID
        self.detail = detail
    }
}
