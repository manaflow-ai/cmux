/// One effective screen classification tied to a foreground process generation.
public struct AgentTerminalStateClassification: Sendable, Equatable {
    /// The recognized profile, or `nil` for an unsupported process.
    public let familyID: String?
    /// Existing cmux status key for lifecycle/sidebar integration.
    public let statusKey: String?
    /// The inferred semantic state.
    public let state: AgentTerminalSemanticState
    /// The process generation that produced the result.
    public let processIdentity: AgentTerminalProcessIdentity

    /// Creates a classification result.
    public init(familyID: String?, statusKey: String?, state: AgentTerminalSemanticState, processIdentity: AgentTerminalProcessIdentity) {
        self.familyID = familyID
        self.statusKey = statusKey
        self.state = state
        self.processIdentity = processIdentity
    }
}
