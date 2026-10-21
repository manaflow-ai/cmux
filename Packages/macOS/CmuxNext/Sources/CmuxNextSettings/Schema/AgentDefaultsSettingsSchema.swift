import CmuxNextDesign

/// The defaults a new agent chat starts with (Agents > Agent Chat). acpmux
/// reads `agents.defaultPermissionMode` at each new chat
/// (`cmux-tui/crates/acpmux/src/hub/start_mode.rs`): a mode picked in a chat
/// wins until this setting changes again. `agents.restartChatsAfterUpdate` (on by default) moves
/// every chat to an agent CLI version an update just installed.
nonisolated enum AgentDefaultsSettingsSchema {
    static let permissionModePath = ["agents", "defaultPermissionMode"]
    /// acpmux reads it at each agent CLI update (`hub/health_view/harness_updated.rs`).
    static let restartAfterUpdatePath = ["agents", "restartChatsAfterUpdate"]

    static var descriptors: [SettingDescriptor] {
        [SettingDescriptor(
            permissionModePath, section: .general,
            group: SettingsText.keyed("settings.group.agentChat", "Agent Chat"),
            title: SettingsText.keyed("settings.agents.defaultPermissionMode", "Permission Mode for New Chats"),
            help: SettingsText.keyed("settings.agents.defaultPermissionMode.help",
                                     "What a new chat may do without asking. Picking a mode in a chat sets it too, until you change this setting again."),
            kind: .choice([
                SettingChoice("fullAccess", SettingsText.keyed("settings.choice.permissionFullAccess", "Full Access")),
                SettingChoice("standard", SettingsText.keyed("settings.choice.permissionStandard", "Harness Default")),
                SettingChoice("ask", SettingsText.keyed("settings.choice.permissionAsk", "Ask Before Changes")),
            ]),
            default: .string("fullAccess"),
            keywords: ["permission", "mode", "full access", "ask", "approval", "yolo", "bypass", "agent", "new chat"]
        ), SettingDescriptor(
            restartAfterUpdatePath, section: .general,
            group: SettingsText.keyed("settings.group.agentChat", "Agent Chat"),
            title: SettingsText.keyed("settings.agents.restartChatsAfterUpdate", "Restart Chats Automatically After an Agent Update"),
            help: SettingsText.keyed("settings.agents.restartChatsAfterUpdate.help",
                                     "After Claude Code, Codex or another agent updates, every chat moves to the new version: an idle chat at once, a busy one when its turn ends. Off, each chat offers Restart Chat."),
            kind: .toggle, default: .bool(true),
            keywords: ["update", "restart", "harness", "claude code", "codex", "agent", "version", "upgrade"]
        )]
    }
}
