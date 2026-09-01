import Foundation

extension CommandPaletteSettingsToggleCommands {
    static func agentSessionAutoResumeDescriptor(
        sectionTitle: @escaping @Sendable () -> String
    ) -> CommandPaletteSettingToggleDescriptor {
        CommandPaletteSettingToggleDescriptor(
            commandId: commandIdPrefix + "autoResumeAgentSessions",
            settingsKey: "terminal.autoResumeAgentSessions",
            title: {
                String(
                    localized: "settings.terminal.agentAutoResume",
                    defaultValue: "Resume Agent Sessions on Reopen"
                )
            },
            sectionTitle: sectionTitle,
            keywords: [
                "terminal.autoResumeAgentSessions",
                "terminal",
                "agent",
                "resume",
                "sessions",
                "reopen",
                "restore",
            ],
            isOn: { defaults in
                AgentSessionAutoResumeSettings.isEnabled(defaults: defaults)
            },
            setOn: { newValue, defaults, notificationCenter in
                AgentSessionAutoResumeSettings.setEnabled(
                    newValue,
                    defaults: defaults,
                    notificationCenter: notificationCenter
                )
            }
        )
    }

    static func agentSessionAutoRetryDescriptor(
        sectionTitle: @escaping @Sendable () -> String
    ) -> CommandPaletteSettingToggleDescriptor {
        CommandPaletteSettingToggleDescriptor(
            commandId: commandIdPrefix + "autoRetryAgentSessions",
            settingsKey: "terminal.autoRetryAgentSessions",
            title: {
                String(
                    localized: "settings.terminal.agentAutoRetry",
                    defaultValue: "Retry Stalled Agent Sessions"
                )
            },
            sectionTitle: sectionTitle,
            keywords: [
                "terminal.autoRetryAgentSessions",
                "terminal",
                "agent",
                "stall",
                "retry",
                "rate",
                "limit",
                "overloaded",
            ],
            defaultValue: AgentSessionAutoRetrySettings.defaultAutoRetryAgentSessions,
            defaultsKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey,
            didSet: { _, _, notificationCenter in
                AgentSessionAutoRetrySettings(
                    notificationCenter: notificationCenter
                ).notifyDidChange()
            }
        )
    }
}
