// The paths and defaults are generated from schemas/settings/source/agent-messages.json
// (Schema/SettingsSchema+AgentMessages.generated.swift).

/// `agents.messages.*` in cmux.json: how a message from another agent or a person reaches an
/// agent in a terminal. Only the terminal agent hook helper (cmux-tui `cmux-tui-hook` inbox.rs)
/// acts on it, reading the file when Claude's wake hook starts and before it hands messages
/// over; the app shows and validates the key through its descriptor, so the snapshot keeps no
/// typed copy.
public nonisolated struct AgentMessageSettings: Sendable, Equatable {
    public var claudeWake = AgentMessageSettings.claudeWakeDefault

    public init() {}
}
