/// Authoritative prompt-boundary evidence for one managed-agent turn.
public enum AgentStallPromptBoundary: Equatable, Sendable {
    /// A managed provider hook reported that the agent returned to its prompt.
    case managedPromptIdle
    /// The managed provider is still processing the turn.
    case midTurn
    /// No authoritative managed prompt boundary is available.
    case unknown
}
