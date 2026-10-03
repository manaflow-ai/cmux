import CmuxNextDesign

extension SettingsSchema {
    static var notifications: [SettingDescriptor] {
        let dismissal = SettingsText.keyed("settings.group.dismissal", "Dismissal")
        let banners = SettingsText.keyed("settings.group.banners", "Banners and Sound")
        let ring = SettingsText.keyed("settings.group.attention", "Attention Ring")
        let feed = SettingsText.keyed("settings.group.feedMirror", "Feed")
        let defaults = NotificationPreferences()
        let attention = AttentionSettings()
        let sameAsAbove = SettingsText.keyed("settings.default.sameAsAbove", "Same as above")
        let sources: [(NotificationSource, SettingText)] = [
            (.agent, SettingsText.keyed("settings.notifications.source.agent", "Agents")),
            (.terminal, SettingsText.keyed("settings.notifications.source.terminal", "Terminal Programs")),
            (.cli, SettingsText.keyed("settings.notifications.source.cli", "cmux notify")),
        ]
        var rows = [
            SettingDescriptor(
                ["notifications", "dismissal"], section: .notifications, group: dismissal,
                title: SettingsText.keyed("settings.notifications.dismissal", "Clear Notification When"),
                kind: .choice(dismissalChoices), default: .string(defaults.dismissal.rawValue), keywords: ["read", "unread"]
            ),
            SettingDescriptor(
                ["notifications", "timeoutSeconds"], section: .notifications, group: dismissal,
                title: SettingsText.keyed("settings.notifications.timeoutSeconds", "Timeout"),
                help: SettingsText.keyed("settings.notifications.timeoutSeconds.help", "Used when a source clears after a timeout."),
                kind: .number(SettingNumber(NotificationPreferences.timeoutRange, step: 5, unit: .seconds)),
                default: .number(defaults.timeoutSeconds)
            ),
        ]
        rows += sources.map { source, title in
            SettingDescriptor(
                ["notifications", "sources", source.rawValue, "dismissal"], section: .notifications, group: dismissal,
                title: title, kind: .choice(dismissalChoices), default: nil, defaultLabel: sameAsAbove
            )
        }
        rows += [
            SettingDescriptor(
                ["notifications", "desktop"], section: .notifications, group: banners,
                title: SettingsText.keyed("settings.notifications.desktop", "macOS Banners"),
                kind: .choice([
                    SettingChoice(DesktopNotificationMode.unlessFocused.rawValue, SettingsText.keyed("settings.choice.unlessFocused", "Unless the Pane Is Focused")),
                    SettingChoice(DesktopNotificationMode.always.rawValue, SettingsText.keyed("settings.choice.always", "Always")),
                    SettingChoice(DesktopNotificationMode.whenInactive.rawValue, SettingsText.keyed("settings.choice.whenInactive", "When cmux Is Inactive")),
                    SettingChoice(DesktopNotificationMode.never.rawValue, SettingsText.keyed("settings.choice.never", "Never")),
                ]),
                default: .string(defaults.desktop.rawValue)
            ),
            SettingDescriptor(
                ["notifications", "sound"], section: .notifications, group: banners,
                title: SettingsText.keyed("settings.notifications.sound", "Sound"),
                kind: .sound, default: .string(defaults.sound)
            ),
            SettingDescriptor(
                ["notifications", "quietHours"], section: .notifications, group: banners,
                title: SettingsText.keyed("settings.notifications.quietHours", "Quiet Hours"),
                help: SettingsText.keyed("settings.notifications.quietHours.help", "No banners or sounds between these times."),
                kind: .timeRange, default: nil, defaultLabel: SettingsText.keyed("settings.choice.off", "Off"), keywords: ["do not disturb"]
            ),
            SettingDescriptor(
                ["notifications", "suppressWhileTypingSeconds"], section: .notifications, group: banners,
                title: SettingsText.keyed("settings.notifications.suppressWhileTyping", "Quiet After Typing"),
                help: SettingsText.keyed("settings.notifications.suppressWhileTyping.help", "A pane typed into this recently is marked read at once. 0 turns it off."),
                kind: .number(SettingNumber(NotificationPreferences.typingRange, step: 1, unit: .seconds)),
                default: .number(defaults.suppressWhileTypingSeconds)
            ),
            SettingDescriptor(
                ["status", "runNotifyMinimumSeconds"], section: .notifications, group: banners,
                title: SettingsText.keyed("settings.status.runNotifyMinimumSeconds", "Notify When a Run Takes"),
                help: SettingsText.keyed("settings.status.runNotifyMinimumSeconds.help",
                                        "cmux status run notifies when the command took at least this long."),
                kind: .number(SettingNumber(StatusBehaviorSettings.runNotifyRange, step: 1, unit: .seconds)),
                default: .number(StatusBehaviorSettings().runNotifyMinimumSeconds)
            ),
            SettingDescriptor(
                ["status", "runNotifyWhenVisible"], section: .notifications, group: banners,
                title: SettingsText.keyed("settings.status.runNotifyWhenVisible", "Notify Even When the Terminal Is Visible"),
                kind: .toggle, default: .bool(StatusBehaviorSettings().runNotifyWhenVisible)
            ),
            SettingDescriptor(
                ["notifications", "dockBadge"], section: .notifications, group: banners,
                title: SettingsText.keyed("settings.notifications.dockBadge", "Unread Count on Dock Icon"),
                kind: .toggle, default: .bool(defaults.dockBadge)
            ),
            SettingDescriptor(
                ["feed", "mirrorNotifications", "agents"], section: .notifications, group: feed,
                title: SettingsText.keyed("settings.feed.mirrorAgents", "Copy Agent Notifications to the Feed"),
                help: SettingsText.keyed("settings.feed.mirrorAgents.help",
                                        "Notifications from agents and cmux notify go to your cmux account's feed and can reach your iPhone."),
                kind: .toggle, default: .bool(defaults.feedMirror.agents), keywords: ["cloud", "iphone", "push"]
            ),
            SettingDescriptor(
                ["feed", "mirrorNotifications", "terminal"], section: .notifications, group: feed,
                title: SettingsText.keyed("settings.feed.mirrorTerminal", "Copy Terminal Notifications to the Feed"),
                help: SettingsText.keyed("settings.feed.mirrorTerminal.help",
                                        "Notifications that programs send through the terminal can contain secrets. Off sends nothing to your cmux account."),
                kind: .choice([
                    SettingChoice(FeedTerminalMirror.off.rawValue, SettingsText.keyed("settings.choice.feedMirror.off", "Off")),
                    SettingChoice(FeedTerminalMirror.title.rawValue, SettingsText.keyed("settings.choice.feedMirror.title", "Title Only")),
                    SettingChoice(FeedTerminalMirror.full.rawValue, SettingsText.keyed("settings.choice.feedMirror.full", "Title and Text")),
                ]),
                default: .string(defaults.feedMirror.terminal.rawValue), keywords: ["cloud", "iphone", "push", "osc"]
            ),
            SettingDescriptor(
                ["notifications", "attention", "style"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.style", "Style"),
                kind: .choice([
                    SettingChoice(AttentionStyle.blink.rawValue, SettingsText.keyed("settings.choice.blink", "Blink")),
                    SettingChoice(AttentionStyle.pulse.rawValue, SettingsText.keyed("settings.choice.pulse", "Pulse")),
                    SettingChoice(AttentionStyle.steady.rawValue, SettingsText.keyed("settings.choice.steady", "Steady")),
                    SettingChoice(AttentionStyle.none.rawValue, SettingsText.keyed("settings.choice.none", "None")),
                ]),
                default: .string(attention.style.rawValue), keywords: ["ring", "flash"]
            ),
            SettingDescriptor(
                ["notifications", "attention", "color"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.color", "Color"),
                kind: .color, default: nil, defaultLabel: SettingsText.keyed("settings.default.theme", "Theme")
            ),
            SettingDescriptor(
                ["notifications", "attention", "width"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.width", "Width"),
                kind: .number(points(AttentionSettings.widthRange, step: 0.5)), default: .number(Double(attention.width))
            ),
            SettingDescriptor(
                ["notifications", "attention", "blinkCount"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.blinkCount", "Blinks"),
                kind: .number(SettingNumber(Double(AttentionSettings.blinkRange.lowerBound)...Double(AttentionSettings.blinkRange.upperBound),
                                            step: 1, unit: .count)),
                default: .number(Double(attention.blinkCount))
            ),
            SettingDescriptor(
                ["notifications", "attention", "duration"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.duration", "Pulse Duration"),
                kind: .number(SettingNumber(AttentionSettings.durationRange, step: 0.5, unit: .seconds)),
                default: .number(attention.duration)
            ),
            SettingDescriptor(
                ["notifications", "attention", "persist"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.persist", "Keep Ring Until Read"),
                kind: .toggle, default: .bool(attention.persists)
            ),
            SettingDescriptor(
                ["notifications", "attention", "showOnTab"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.showOnTab", "Mark the Tab"),
                kind: .toggle, default: .bool(attention.showsOnTab)
            ),
            SettingDescriptor(
                ["notifications", "attention", "showOnSidebar"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.showOnSidebar", "Mark the Sidebar Row"),
                kind: .toggle, default: .bool(attention.showsOnSidebar)
            ),
        ]
        return rows
    }

    static var dismissalChoices: [SettingChoice] {
        [
            SettingChoice(NotificationDismissal.keystroke.rawValue, SettingsText.keyed("settings.choice.keystroke", "You Type in the Pane")),
            SettingChoice(NotificationDismissal.click.rawValue, SettingsText.keyed("settings.choice.click", "You Click or Type in the Pane")),
            SettingChoice(NotificationDismissal.focus.rawValue, SettingsText.keyed("settings.choice.focus", "The Pane Is Focused")),
            SettingChoice(NotificationDismissal.explicit.rawValue, SettingsText.keyed("settings.choice.explicit", "You Open It")),
            SettingChoice(NotificationDismissal.timeout.rawValue, SettingsText.keyed("settings.choice.timeout", "After the Timeout")),
            SettingChoice(NotificationDismissal.never.rawValue, SettingsText.keyed("settings.choice.neverDismiss", "You Mark It Read")),
        ]
    }
}
