import CmuxNextDesign

/// The defaults a new agent chat starts with (Agents > Agent Chat). acpmux
/// reads `agents.defaultPermissionMode` at each new chat
/// (`cmux-tui/crates/acpmux/src/hub/start_mode.rs`): a mode picked in a chat
/// applies to that chat only (Leo 2026-10-21). A value MDM or the team
/// policy forces reaches acpmux through the app's settings push
/// (`ChatSettings`) and wins over the settings file.
nonisolated enum AgentDefaultsSettingsSchema {
    static let permissionModePath = ["agents", "defaultPermissionMode"]

    static var descriptors: [SettingDescriptor] {
        [SettingDescriptor(
            permissionModePath, section: .general,
            group: SettingsText.keyed("settings.group.agentChat", "Agent Chat"),
            title: SettingsText.keyed("settings.agents.defaultPermissionMode", "Permission Mode for New Chats"),
            help: SettingsText.keyed("settings.agents.defaultPermissionMode.help",
                                     "What a new chat may do without asking. A mode you pick in a chat applies to that chat only."),
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
