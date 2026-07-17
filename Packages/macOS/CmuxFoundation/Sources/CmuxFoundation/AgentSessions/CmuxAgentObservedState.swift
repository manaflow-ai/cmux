/// A provider-neutral semantic state observed from a live agent terminal.
public enum CmuxAgentObservedState: String, Codable, Sendable, CaseIterable, Equatable {
    /// The agent is ready for another turn.
    case idle
    /// The agent is executing a turn or tool.
    case working
    /// The agent requires a human decision or credential.
    case blocked
}
