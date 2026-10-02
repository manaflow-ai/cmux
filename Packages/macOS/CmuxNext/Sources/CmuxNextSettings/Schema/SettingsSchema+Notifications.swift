import CmuxNextDesign

extension SettingsSchema {
    static var notifications: [SettingDescriptor] {
        let dismissal = SettingsText.text("settings.group.dismissal", "Dismissal")
        let banners = SettingsText.text("settings.group.banners", "Banners and Sound")
        let ring = SettingsText.text("settings.group.attention", "Attention Ring")
        let defaults = NotificationPreferences()
        let attention = AttentionSettings()
        let sameAsAbove = SettingsText.text("settings.default.sameAsAbove", "Same as above")
        let sources: [(NotificationSource, String)] = [
            (.agent, SettingsText.text("settings.notifications.source.agent", "Agents")),
            (.terminal, SettingsText.text("settings.notifications.source.terminal", "Terminal Programs")),
            (.cli, SettingsText.text("settings.notifications.source.cli", "cmux notify")),
        ]
        var rows = [
            SettingDescriptor(
                ["notifications", "dismissal"], section: .notifications, group: dismissal,
                title: SettingsText.text("settings.notifications.dismissal", "Clear Notification When"),
                kind: .choice(dismissalChoices), default: .string(defaults.dismissal.rawValue), keywords: ["read", "unread"]
            ),
            SettingDescriptor(
                ["notifications", "timeoutSeconds"], section: .notifications, group: dismissal,
                title: SettingsText.text("settings.notifications.timeoutSeconds", "Timeout"),
                help: SettingsText.text("settings.notifications.timeoutSeconds.help", "Used when a source clears after a timeout."),
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
                title: SettingsText.text("settings.notifications.desktop", "macOS Banners"),
                kind: .choice([
                    SettingChoice(DesktopNotificationMode.unlessFocused.rawValue, SettingsText.text("settings.choice.unlessFocused", "Unless the Pane Is Focused")),
                    SettingChoice(DesktopNotificationMode.always.rawValue, SettingsText.text("settings.choice.always", "Always")),
                    SettingChoice(DesktopNotificationMode.whenInactive.rawValue, SettingsText.text("settings.choice.whenInactive", "When cmux Is Inactive")),
                    SettingChoice(DesktopNotificationMode.never.rawValue, SettingsText.text("settings.choice.never", "Never")),
                ]),
                default: .string(defaults.desktop.rawValue)
            ),
            SettingDescriptor(
                ["notifications", "sound"], section: .notifications, group: banners,
                title: SettingsText.text("settings.notifications.sound", "Sound"),
                kind: .sound, default: .string(defaults.sound)
            ),
            SettingDescriptor(
                ["notifications", "quietHours"], section: .notifications, group: banners,
                title: SettingsText.text("settings.notifications.quietHours", "Quiet Hours"),
                help: SettingsText.text("settings.notifications.quietHours.help", "No banners or sounds between these times."),
                kind: .timeRange, default: nil, defaultLabel: SettingsText.text("settings.choice.off", "Off"), keywords: ["do not disturb"]
            ),
            SettingDescriptor(
                ["notifications", "suppressWhileTypingSeconds"], section: .notifications, group: banners,
                title: SettingsText.text("settings.notifications.suppressWhileTyping", "Quiet After Typing"),
                help: SettingsText.text("settings.notifications.suppressWhileTyping.help", "A pane typed into this recently is marked read at once. 0 turns it off."),
                kind: .number(SettingNumber(NotificationPreferences.typingRange, step: 1, unit: .seconds)),
                default: .number(defaults.suppressWhileTypingSeconds)
            ),
            SettingDescriptor(
                ["status", "runNotifyMinimumSeconds"], section: .notifications, group: banners,
                title: SettingsText.text("settings.status.runNotifyMinimumSeconds", "Notify When a Run Takes"),
                help: SettingsText.text("settings.status.runNotifyMinimumSeconds.help",
                                        "cmux status run notifies when the command took at least this long."),
                kind: .number(SettingNumber(StatusBehaviorSettings.runNotifyRange, step: 1, unit: .seconds)),
                default: .number(StatusBehaviorSettings().runNotifyMinimumSeconds)
            ),
            SettingDescriptor(
                ["status", "runNotifyWhenVisible"], section: .notifications, group: banners,
                title: SettingsText.text("settings.status.runNotifyWhenVisible", "Notify Even When the Terminal Is Visible"),
                kind: .toggle, default: .bool(StatusBehaviorSettings().runNotifyWhenVisible)
            ),
            SettingDescriptor(
                ["notifications", "dockBadge"], section: .notifications, group: banners,
                title: SettingsText.text("settings.notifications.dockBadge", "Unread Count on Dock Icon"),
                kind: .toggle, default: .bool(defaults.dockBadge)
            ),
            SettingDescriptor(
                ["notifications", "attention", "style"], section: .notifications, group: ring,
                title: SettingsText.text("settings.attention.style", "Style"),
                kind: .choice([
                    SettingChoice(AttentionStyle.blink.rawValue, SettingsText.text("settings.choice.blink", "Blink")),
                    SettingChoice(AttentionStyle.pulse.rawValue, SettingsText.text("settings.choice.pulse", "Pulse")),
                    SettingChoice(AttentionStyle.steady.rawValue, SettingsText.text("settings.choice.steady", "Steady")),
                    SettingChoice(AttentionStyle.none.rawValue, SettingsText.text("settings.choice.none", "None")),
                ]),
                default: .string(attention.style.rawValue), keywords: ["ring", "flash"]
            ),
            SettingDescriptor(
                ["notifications", "attention", "color"], section: .notifications, group: ring,
                title: SettingsText.text("settings.attention.color", "Color"),
                kind: .color, default: nil, defaultLabel: SettingsText.text("settings.default.theme", "Theme")
            ),
            SettingDescriptor(
                ["notifications", "attention", "width"], section: .notifications, group: ring,
                title: SettingsText.text("settings.attention.width", "Width"),
                kind: .number(points(AttentionSettings.widthRange, step: 0.5)), default: .number(Double(attention.width))
            ),
            SettingDescriptor(
                ["notifications", "attention", "blinkCount"], section: .notifications, group: ring,
                title: SettingsText.text("settings.attention.blinkCount", "Blinks"),
                kind: .number(SettingNumber(Double(AttentionSettings.blinkRange.lowerBound)...Double(AttentionSettings.blinkRange.upperBound),
                                            step: 1, unit: .count)),
                default: .number(Double(attention.blinkCount))
            ),
            SettingDescriptor(
                ["notifications", "attention", "duration"], section: .notifications, group: ring,
                title: SettingsText.text("settings.attention.duration", "Pulse Duration"),
                kind: .number(SettingNumber(AttentionSettings.durationRange, step: 0.5, unit: .seconds)),
                default: .number(attention.duration)
            ),
            SettingDescriptor(
                ["notifications", "attention", "persist"], section: .notifications, group: ring,
                title: SettingsText.text("settings.attention.persist", "Keep Ring Until Read"),
                kind: .toggle, default: .bool(attention.persists)
            ),
            SettingDescriptor(
                ["notifications", "attention", "showOnTab"], section: .notifications, group: ring,
                title: SettingsText.text("settings.attention.showOnTab", "Mark the Tab"),
                kind: .toggle, default: .bool(attention.showsOnTab)
            ),
            SettingDescriptor(
                ["notifications", "attention", "showOnSidebar"], section: .notifications, group: ring,
                title: SettingsText.text("settings.attention.showOnSidebar", "Mark the Sidebar Row"),
                kind: .toggle, default: .bool(attention.showsOnSidebar)
            ),
        ]
        return rows
    }

    static var dismissalChoices: [SettingChoice] {
        [
            SettingChoice(NotificationDismissal.keystroke.rawValue, SettingsText.text("settings.choice.keystroke", "You Type in the Pane")),
            SettingChoice(NotificationDismissal.click.rawValue, SettingsText.text("settings.choice.click", "You Click or Type in the Pane")),
            SettingChoice(NotificationDismissal.focus.rawValue, SettingsText.text("settings.choice.focus", "The Pane Is Focused")),
            SettingChoice(NotificationDismissal.explicit.rawValue, SettingsText.text("settings.choice.explicit", "You Open It")),
            SettingChoice(NotificationDismissal.timeout.rawValue, SettingsText.text("settings.choice.timeout", "After the Timeout")),
            SettingChoice(NotificationDismissal.never.rawValue, SettingsText.text("settings.choice.neverDismiss", "You Mark It Read")),
        ]
    }
}
