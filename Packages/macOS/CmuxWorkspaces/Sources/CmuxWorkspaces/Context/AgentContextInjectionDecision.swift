/// The result of evaluating one possible recovery step.
public enum AgentContextInjectionDecision: Equatable, Sendable {
    /// The caller may inject the returned step now.
    case inject(AgentContextInjectionStep)
    /// The caller must wait for a real lifecycle signal before retrying.
    case wait(AgentContextInjectionBlockReason)
    /// The requested action is destructive or otherwise unsafe to automate.
    case unsafe(AgentContextInjectionBlockReason)
}
