/// Lifecycle evidence supplied by the managed-agent hook integration.
public enum AgentContextLifecycleState: String, Codable, CaseIterable, Sendable {
    /// No authoritative lifecycle report exists.
    case unknown
    /// The agent is currently producing a turn.
    case running
    /// The agent is waiting at its prompt and can accept a user command.
    case idle
    /// The agent is blocked on a permission or other dialog.
    case needsInput
}
