import Foundation

extension CommandPaletteSettingsToggleCommands {
    static func agentSessionAutoRetryDescriptor(
        sectionTitle: @escaping @Sendable () -> String
    ) -> CommandPaletteSettingToggleDescriptor {
        CommandPaletteSettingToggleDescriptor(
            commandId: commandIdPrefix + "autoRetryAgentSessions",
            settingsKey: "terminal.autoRetryAgentSessions",
            title: {
                String(
                    localized: "settings.terminal.agentAutoRetry",
                    defaultValue: "Retry Failed Agent Sessions"
                )
            },
            sectionTitle: sectionTitle,
            keywords: ["terminal.autoRetryAgentSessions", "terminal", "agent", "retry", "resume", "error", "failure"],
            isOn: { defaults in
                AgentSessionAutoRetrySettings(defaults: defaults).isEnabled
            },
            setOn: { newValue, defaults, notificationCenter in
                AgentSessionAutoRetrySettings(
                    defaults: defaults,
                    notificationCenter: notificationCenter
                ).setEnabled(newValue)
            }
        )
    }
}
