// The paths and defaults are generated from schemas/settings/source/agent-guidance.json
// (Schema/SettingsSchema+AgentGuidance.generated.swift); this file only parses.

/// `agents.guidance.*` in cmux.json: whether new agent chats get cmux's built-in guidance
/// (per harness family) and the person's own skills from `~/.config/cmux/skills`. The acpmux
/// daemon reads the same file when it creates a chat (`agent_guidance.rs`); the app shows and
/// validates them.
public nonisolated struct AgentGuidanceSettings: Sendable, Equatable {
    public var claude = AgentGuidanceSettings.guidanceClaudeDefault
    public var codex = AgentGuidanceSettings.guidanceCodexDefault
    public var otherAgents = AgentGuidanceSettings.guidanceOtherAgentsDefault
    public var userSkills = AgentGuidanceSettings.guidanceUserSkillsDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["agents", "guidance"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("claude") { settings.claude = value }
        if let value = reader.bool("codex") { settings.codex = value }
        if let value = reader.bool("otherAgents") { settings.otherAgents = value }
        if let value = reader.bool("userSkills") { settings.userSkills = value }
        diagnostics += reader.diagnostics
        return settings
    }
}
