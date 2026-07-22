/// The observable outcome of consulting ``AgentLaunchGuard``.
public enum AgentLaunchGuardResult: Equatable, Sendable {
    /// The launch command was accepted by the terminal.
    case launched
    /// The launch command was deliberately not typed.
    case suppressed(AgentLaunchSuppressionReason)
    /// An already-running agent received the prompt through the prompt injector.
    case promptRerouted(queued: Bool)
    /// The terminal rejected the launch or prompt sequence.
    case failed(String)
}
