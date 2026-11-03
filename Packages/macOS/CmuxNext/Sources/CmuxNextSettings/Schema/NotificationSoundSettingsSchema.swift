/// `notifications.sounds.*` rows (``NotificationSoundPreferences``): the Notifications page's
/// per-event sounds, volume, timing and cooldown; the per-level maps are set from the sidebar row and
/// group menus, the palette and the CLI, so the page hides them.
nonisolated enum NotificationSoundSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.sounds", "Sounds")
        let defaults = NotificationSoundPreferences()
        let sameAsSound = SettingsText.keyed("settings.notifications.sounds.sameAsSound", "Same as Sound")
        let events: [(NotificationSoundEvent, SettingText)] = [
            (.finished, SettingsText.keyed("settings.notifications.sounds.event.finished", "Agent Finished")),
            (.needsInput, SettingsText.keyed("settings.notifications.sounds.event.needsInput", "Agent Needs Input")),
            (.error, SettingsText.keyed("settings.notifications.sounds.event.error", "Error")),
            (.bell, SettingsText.keyed("settings.notifications.sounds.event.bell", "Terminal Notification")),
            (.message, SettingsText.keyed("settings.notifications.sounds.event.message", "cmux notify Message")),
        ]
        var rows = events.map { event, title in
            SettingDescriptor(
                ["notifications", "sounds", "events", event.rawValue], section: .notifications, group: group,
                title: title, kind: .sound, default: nil, defaultLabel: sameAsSound, keywords: ["sound", "alert", "chime"]
            )
        }
        rows += [
            SettingDescriptor(
                ["notifications", "sounds", "volume"], section: .notifications, group: group,
                title: SettingsText.keyed("settings.notifications.sounds.volume", "Volume"),
                help: SettingsText.keyed("settings.notifications.sounds.volume.help",
                                        "Sounds cmux plays itself. A banner's default sound follows the system alert volume."),
                kind: .number(SettingNumber(NotificationSoundPreferences.volumeRange, step: 0.05, unit: .fraction)),
                default: .number(defaults.volume), keywords: ["sound", "loud", "quiet"]
            ),
            SettingDescriptor(
                ["notifications", "sounds", "when"], section: .notifications, group: group,
                title: SettingsText.keyed("settings.notifications.sounds.when", "Play Sounds"),
                kind: .choice([
                    SettingChoice(NotificationSoundTiming.unlessViewed.rawValue,
                                  SettingsText.keyed("settings.notifications.sounds.when.unlessViewed", "Unless the Pane Is in Front")),
                    SettingChoice(NotificationSoundTiming.whenInactive.rawValue,
                                  SettingsText.keyed("settings.notifications.sounds.when.whenInactive", "Only When cmux Is Inactive")),
                    SettingChoice(NotificationSoundTiming.always.rawValue,
                                  SettingsText.keyed("settings.notifications.sounds.when.always", "Always")),
                ]),
                default: .string(defaults.when.rawValue), keywords: ["sound", "focused", "background"]
            ),
            SettingDescriptor(
                ["notifications", "sounds", "cooldownSeconds"], section: .notifications, group: group,
                title: SettingsText.keyed("settings.notifications.sounds.cooldown", "Burst Cooldown"),
                help: SettingsText.keyed("settings.notifications.sounds.cooldown.help",
                                        "Many notifications at once sound once. An agent asking for input still sounds. 0 turns it off."),
                kind: .number(SettingNumber(NotificationSoundPreferences.cooldownRange, step: 0.5, unit: .seconds)),
                default: .number(defaults.cooldownSeconds), keywords: ["sound", "rate limit", "throttle", "burst"]
            ),
        ]
        let levels: [(String, SettingText, SettingText)] = [
            ("workspaces", SettingsText.keyed("settings.notifications.sounds.workspaces", "Workspace Sounds"),
             SettingsText.keyed("settings.notifications.sounds.workspaces.help", "Sounds per workspace id. Set one from the workspace's sidebar menu.")),
            ("groups", SettingsText.keyed("settings.notifications.sounds.groups", "Group Sounds"),
             SettingsText.keyed("settings.notifications.sounds.groups.help", "Sounds per group id or name. Set one from the group's sidebar menu.")),
            ("agents", SettingsText.keyed("settings.notifications.sounds.agents", "Agent Sounds"),
             SettingsText.keyed("settings.notifications.sounds.agents.help", "Sounds per agent kind, such as claude or codex.")),
        ]
        rows += levels.map { key, title, help in
            SettingDescriptor(
                ["notifications", "sounds", key], section: .notifications, group: group,
                title: title, help: help, kind: .soundRules, default: .object([:]), keywords: ["sound", "mute"]
            )
            .hiddenFromSettingsPage("ids and per-level rules; set from the sidebar row and group menus, the palette and the CLI")
        }
        return rows
    }

    /// Looks and sound only: an agent (the CLI, MCP) may set every one.
    static var agentSettableKeys: Set<String> { Set(descriptors.map(\.id)) }
}
