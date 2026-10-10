/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum UpdateSettingsSchema {
    /// Automatic updates under General (R114): every step of checking,
    /// downloading and installing is a row; the defaults keep cmux current
    /// with no clicks beyond the one that relaunches.
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.updates", "Updates")
        let defaults = UpdatesSettings()
        return [
            SettingDescriptor(
                UpdatesSettings.checkAutomaticallyPath, section: .general, group: group,
                title: SettingsText.keyed("settings.updates.checkAutomatically", "Check for Updates Automatically"),
                kind: .toggle, default: .bool(defaults.checkAutomatically),
                keywords: ["update", "sparkle", "check", "automatic"]
            ),
            SettingDescriptor(
                UpdatesSettings.checkIntervalPath, section: .general, group: group,
                title: SettingsText.keyed("settings.updates.checkInterval", "Check Every"),
                kind: .number(SettingNumber(UpdatesSettings.checkIntervalRange, step: 900, unit: .seconds)),
                default: .number(defaults.checkIntervalSeconds),
                keywords: ["update", "interval", "frequency", "hourly", "daily"]
            ),
            SettingDescriptor(
                UpdatesSettings.downloadAutomaticallyPath, section: .general, group: group,
                title: SettingsText.keyed("settings.updates.downloadAutomatically", "Download Updates Automatically"),
                help: SettingsText.keyed("settings.updates.downloadAutomatically.help",
                                        "Off: a found update waits, and one click downloads and installs it."),
                kind: .toggle, default: .bool(defaults.downloadAutomatically),
                keywords: ["update", "download", "background", "metered"]
            ),
            SettingDescriptor(
                UpdatesSettings.meteredNetworkPath, section: .general, group: group,
                title: SettingsText.keyed("settings.updates.meteredNetwork", "On Metered Networks"),
                help: SettingsText.keyed("settings.updates.meteredNetwork.help",
                                        "While downloads wait, a found update shows on Settings and one click downloads it."),
                kind: .choice([
                    SettingChoice(UpdatesMeteredSetting.deferLowData.rawValue,
                                  SettingsText.keyed("settings.choice.updatesDeferLowData", "Wait in Low Data Mode")),
                    SettingChoice(UpdatesMeteredSetting.deferExpensive.rawValue,
                                  SettingsText.keyed("settings.choice.updatesDeferExpensive", "Wait on Cellular and Low Data")),
                    SettingChoice(UpdatesMeteredSetting.download.rawValue,
                                  SettingsText.keyed("settings.choice.updatesDownloadAlways", "Always Download")),
                ]),
                default: .string(defaults.meteredNetwork.rawValue),
                keywords: ["update", "metered", "cellular", "low data", "hotspot"]
            ),
            SettingDescriptor(
                UpdatesSettings.installOnQuitPath, section: .general, group: group,
                title: SettingsText.keyed("settings.updates.installOnQuit", "Install Updates When Quitting"),
                help: SettingsText.keyed("settings.updates.installOnQuit.help",
                                        "A downloaded update installs as cmux quits. Terminals keep running."),
                kind: .toggle, default: .bool(defaults.installOnQuit),
                keywords: ["update", "install", "quit"]
            ),
            SettingDescriptor(
                UpdatesSettings.notifyPath, section: .general, group: group,
                title: SettingsText.keyed("settings.updates.notify", "When an Update Is Ready"),
                kind: .choice([
                    SettingChoice(UpdatesNotifySetting.badge.rawValue, SettingsText.keyed("settings.choice.updatesBadge", "Badge Settings Only")),
                    SettingChoice(UpdatesNotifySetting.silent.rawValue, SettingsText.keyed("settings.choice.updatesSilent", "Install Silently on Quit")),
                ]),
                default: .string(defaults.notify.rawValue),
                keywords: ["update", "notify", "badge", "silent"]
            ),
            SettingDescriptor(
                UpdatesSettings.keepPreviousVersionsPath, section: .general, group: group,
                title: SettingsText.keyed("settings.updates.keepPreviousVersions", "Keep Previous Versions"),
                help: SettingsText.keyed("settings.updates.keepPreviousVersions.help",
                                        "Earlier builds kept so you can roll back. Uses almost no disk until files change."),
                kind: .number(SettingNumber(UpdatesSettings.keepPreviousVersionsRange, step: 1, unit: .count)),
                default: .number(Double(defaults.keepPreviousVersions)),
                keywords: ["update", "rollback", "previous", "downgrade"]
            ),
            SettingDescriptor(
                UpdatesSettings.showWhatsNewPath, section: .general, group: group,
                title: SettingsText.keyed("settings.updates.showWhatsNew", "Show What's New After Updates"),
                help: SettingsText.keyed("settings.updates.showWhatsNew.help",
                                        "After an update, a What's New item shows at the top of the sidebar until you open it."),
                kind: .toggle, default: .bool(defaults.showWhatsNew),
                keywords: ["whats new", "release notes", "changelog", "update", "sidebar"]
            ),
        ]
    }

    /// The cmux announcement cards (R114).
    static var announcements: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.announcements", "Announcements")
        let defaults = AnnouncementsSettings()
        return [
            SettingDescriptor(
                AnnouncementsSettings.enabledPath, section: .general, group: group,
                title: SettingsText.keyed("settings.announcements.enabled", "Show Announcements"),
                help: SettingsText.keyed("settings.announcements.enabled.help",
                                        "Short cards from the cmux team above Settings, shown when the pointer is over the sidebar."),
                kind: .toggle, default: .bool(defaults.enabled), keywords: ["announcements", "news", "cards", "whats new"]
            ),
            SettingDescriptor(
                AnnouncementsSettings.fetchPath, section: .general, group: group,
                title: SettingsText.keyed("settings.announcements.fetch", "Download Announcements"),
                help: SettingsText.keyed("settings.announcements.fetch.help",
                                        "Off: cmux never asks the network for announcements. The request carries no identifiers."),
                kind: .toggle, default: .bool(defaults.fetch), keywords: ["announcements", "privacy", "offline", "network"]
            ),
        ]
    }
}
