/// One effective screen classification tied to a foreground process generation.
public struct AgentTerminalStateClassification: Sendable, Equatable {
    /// The recognized profile, or `nil` for an unsupported process.
    public let familyID: String?
    /// Existing cmux status key for lifecycle/sidebar integration.
    public let statusKey: String?
    /// Canonical hook/session provider identifier, when recognized.
    public let sessionProviderID: String?
    /// Whether complete lifecycle hooks take precedence over screen evidence.
    public let lifecycleAuthoritative: Bool
    /// The inferred semantic state.
    public let state: AgentTerminalSemanticState
    /// The process generation that produced the result.
    public let processIdentity: AgentTerminalProcessIdentity

    /// Creates a classification result.
    public init(
        familyID: String?,
        statusKey: String?,
        sessionProviderID: String? = nil,
        lifecycleAuthoritative: Bool = false,
        state: AgentTerminalSemanticState,
        processIdentity: AgentTerminalProcessIdentity
    ) {
        self.familyID = familyID
        self.statusKey = statusKey
        self.sessionProviderID = sessionProviderID
        self.lifecycleAuthoritative = lifecycleAuthoritative
        self.state = state
        self.processIdentity = processIdentity
    }
}
