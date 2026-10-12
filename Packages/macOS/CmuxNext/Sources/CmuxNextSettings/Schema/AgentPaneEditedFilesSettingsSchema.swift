import CmuxNextDesign

/// The agent chat's edited-files card rows (General > Agent Chat, next to AgentPaneSettingsSchema's reply rows).
nonisolated enum AgentPaneEditedFilesSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.agentChat", "Agent Chat")
        typealias S = AgentPaneEditedFilesSetting
        let fallback = S.fallback
        return [
            SettingDescriptor(
                S.showPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.editedFiles.show", "Edited Files Card"),
                help: SettingsText.keyed("settings.agentPane.editedFiles.show.help",
                                         "The card that lists a turn's edited files, with Undo and View changes."),
                kind: .choice([
                    SettingChoice("always", SettingsText.keyed("settings.choice.editedFilesAlways", "Always")),
                    SettingChoice("collapsed", SettingsText.keyed("settings.choice.editedFilesCollapsed", "Collapsed")),
                    SettingChoice("never", SettingsText.keyed("settings.choice.editedFilesNever", "Never")),
                ]),
                default: .string(fallback.show), keywords: ["edited", "files", "undo", "changes", "agent"]
            ),
            SettingDescriptor(
                S.maxRowsPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.editedFiles.maxRows", "Edited Files Shown"),
                kind: .number(SettingNumber(S.maxRowsRange, step: 1, unit: .count)), default: .number(Double(fallback.maxRows)),
                keywords: ["edited", "files", "rows", "agent"]
            ),
            SettingDescriptor(
                S.scopePath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.editedFiles.scope", "Edited Files Card Covers"),
                kind: .choice([
                    SettingChoice("turn", SettingsText.keyed("settings.choice.editedFilesTurn", "Each Turn")),
                    SettingChoice("session", SettingsText.keyed("settings.choice.editedFilesSession", "The Whole Chat")),
                ]),
                default: .string(fallback.scope), keywords: ["edited", "files", "session", "turn", "agent"]
            ),
        ]
    }

    /// Looks only: agents may change all three.
    static var agentSettableKeys: Set<String> { Set(descriptors.map(\.id)) }
}
