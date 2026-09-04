/// One PTY input step the app may perform after policy approval.
public enum AgentContextInjectionStep: String, Codable, Equatable, Sendable {
    /// Ask the agent to preserve a short handoff before clearing its context.
    case preserveState
    /// Compact the current context.
    case compact
    /// Clear the current context.
    case clear
}
