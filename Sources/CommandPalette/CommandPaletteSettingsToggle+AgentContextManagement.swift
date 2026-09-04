import CmuxSettings
import CmuxWorkspaces

extension CommandPaletteSettingsToggleCommands {
    static var agentContextManagementDescriptor: CommandPaletteSettingToggleDescriptor {
        CommandPaletteSettingToggleDescriptor(
            commandId: commandIdPrefix + "agentContextManagement",
            settingsKey: "terminal.agentContextManagement.enabled",
            title: {
                String(
                    localized: "settings.terminal.agentContextManagement",
                    defaultValue: "Manage Agent Context Pressure"
                )
            },
            sectionTitle: {
                String(localized: "settings.section.terminal", defaultValue: "Terminal")
            },
            keywords: [
                "terminal.agentContextManagement.enabled",
                "terminal",
                "agent",
                "context",
                "pressure",
                "compact",
                "clear",
                "claude",
                "codex",
            ],
            defaultValue: SettingCatalog().terminal.agentContextManagementEnabled.defaultValue,
            defaultsKey: SettingCatalog().terminal.agentContextManagementEnabled.userDefaultsKey,
            didSet: { _, defaults, notificationCenter in
                AgentContextManagementSettings(
                    defaults: defaults,
                    notificationCenter: notificationCenter
                ).notifyDidChange()
            }
        )
    }
}
