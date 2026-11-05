// The paths and defaults are generated from schemas/settings/source/agent-messages.json
// (Schema/SettingsSchema+AgentMessages.generated.swift).

/// `agents.messages.*` in cmux.json: how a message from another agent or a person reaches an
/// agent in a terminal. Only the daemon acts on it: `agent.message.wait` (cmux-tui
/// agent_message_wait.rs) reads the effective value from its settings owner, managed layers
/// included. The app shows and validates the key through its descriptor, so the snapshot keeps
/// no typed copy.
public nonisolated struct AgentMessageSettings: Sendable, Equatable {
    public var claudeWake = AgentMessageSettings.claudeWakeDefault

    public init() {}
}
