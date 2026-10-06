/// Whether an agent's input line is safe to type into.
public enum AgentPromptInputState: Sendable, Equatable {
    /// Nothing typed: the line is blank or shows only the agent's dimmed
    /// placeholder or suggestion.
    case empty
    /// The line holds text the user typed, pasted, or had restored.
    case hasText
    /// The input line wasn't found on screen, so its contents are unknown.
    case unknown
}
