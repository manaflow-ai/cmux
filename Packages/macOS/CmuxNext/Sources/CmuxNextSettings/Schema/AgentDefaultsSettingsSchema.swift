import CmuxNextDesignTokens

/// The defaults a new agent chat starts with (Agents > Agent Chat). acpmux
/// reads `agents.defaultPermissionMode` at each new chat
/// (`cmux-tui/crates/acpmux/src/hub/start_mode.rs`): a mode picked in a chat
/// wins until this setting changes again. A value MDM or the team policy
/// forces reaches acpmux through the app's settings push (`ChatSettings`)
/// and wins over every pick.
nonisolated enum AgentDefaultsSettingsSchema {
    static let permissionModePath = ["agents", "defaultPermissionMode"]

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
        )]
    }
}
