/// The recovery action selected by the user.
public enum AgentContextInjectionAction: String, Codable, CaseIterable, Sendable {
    /// Ask the current agent to compact in place.
    case compact
    /// Start a fresh context with the provider's clear command.
    case clear
}
