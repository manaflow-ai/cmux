import CmuxNextCompat
import CmuxNextDesign

/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum NotificationSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let dismissal = SettingsText.keyed("settings.group.dismissal", "Dismissal")
        let banners = SettingsText.keyed("settings.group.banners", "Banners and Sound")
        let ring = SettingsText.keyed("settings.group.attention", "Attention Ring")
        let feed = SettingsText.keyed("settings.group.feedMirror", "Feed")
        let defaults = NotificationPreferences()
        let attention = AttentionSettings()
        let sameAsAbove = SettingsText.keyed("settings.default.sameAsAbove", "Same as above")
        let sources: [(NotificationSource, SettingText)] = [NotificationSource.agent, .terminal, .cli]
            .map { ($0, $0.settingsTitle) }
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
                summary: SettingsText.keyed("settings.notifications.suppressWhileTyping.summary", "No alerts from a pane you just typed in"),
                kind: .number(SettingNumber(NotificationPreferences.typingRange, step: 1, unit: .seconds)),
                default: .number(defaults.suppressWhileTypingSeconds)
            ),
            SettingDescriptor(
                ["status", "runNotifyMinimumSeconds"], section: .notifications, group: banners,
                title: SettingsText.keyed("settings.status.runNotifyMinimumSeconds", "Notify When a Run Takes"),
                help: SettingsText.keyed("settings.status.runNotifyMinimumSeconds.help",
                                        "cmux status run notifies when the command took at least this long."),
                summary: SettingsText.keyed("settings.status.runNotifyMinimumSeconds.summary", "Long runs notify when they finish"),
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
                ["notifications", "dockBounce"], section: .notifications, group: banners,
                title: SettingsText.keyed("settings.notifications.dockBounce", "Bounce Dock Icon"),
                help: SettingsText.keyed("settings.notifications.dockBounce.help",
                                        "When a notification alerts while cmux isn't the active app."),
                kind: .choice([
                    SettingChoice(DockBounceMode.off.rawValue, SettingsText.keyed("settings.choice.dockBounceOff", "Off")),
                    SettingChoice(DockBounceMode.once.rawValue, SettingsText.keyed("settings.choice.dockBounceOnce", "Once")),
                    SettingChoice(DockBounceMode.untilActive.rawValue, SettingsText.keyed("settings.choice.dockBounceUntilActive", "Until You Switch to cmux")),
                ]),
                default: .string(defaults.dockBounce.rawValue), keywords: ["dock", "bounce", "attention", "badge"]
            ),
            SettingDescriptor(
                ["notifications", "showPreviews"], section: .notifications, group: banners,
                title: SettingsText.keyed("settings.notifications.showPreviews", "Show Message in Banners"),
                help: SettingsText.keyed("settings.notifications.showPreviews.help",
                                        "Whether a banner shows what the agent said, or only where and what state."),
                kind: .choice([
                    SettingChoice(NotificationPreviews.always.rawValue, SettingsText.keyed("settings.choice.previewsAlways", "Always")),
                    SettingChoice(NotificationPreviews.whenUnlocked.rawValue, SettingsText.keyed("settings.choice.previewsWhenUnlocked", "When Unlocked")),
                    SettingChoice(NotificationPreviews.never.rawValue, SettingsText.keyed("settings.choice.previewsNever", "Never")),
                ]),
                default: .string(defaults.showPreviews.rawValue), keywords: ["preview", "privacy", "message", "lock screen", "banner"]
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
                summary: SettingsText.keyed("settings.feed.mirrorTerminal.summary", "Terminal output can contain secrets"),
                kind: .choice([
                    SettingChoice(FeedTerminalMirror.off.rawValue, SettingsText.keyed("settings.choice.feedMirror.off", "Off")),
                    SettingChoice(FeedTerminalMirror.title.rawValue, SettingsText.keyed("settings.choice.feedMirror.title", "Title Only")),
                    SettingChoice(FeedTerminalMirror.full.rawValue, SettingsText.keyed("settings.choice.feedMirror.full", "Title and Text")),
                ]),
                default: .string(defaults.feedMirror.terminal.rawValue), keywords: ["cloud", "iphone", "push", "osc"]
            ),
            SettingDescriptor(
                ["feed", "agentPermissionPrompts"], section: .notifications, group: feed,
                title: SettingsText.keyed("settings.feed.agentPermissionPrompts", "Send Agent Permission Requests to the Feed"),
                help: SettingsText.keyed("settings.feed.agentPermissionPrompts.help",
                                        "Each request's tool and command summary goes to your own cmux feed, so your iPhone can answer it."),
                kind: .toggle, default: .bool(defaults.feedMirror.agentPermissionPrompts),
                keywords: ["cloud", "iphone", "push", "approve", "allow"]
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
                kind: .color, default: nil, defaultLabel: SettingsText.keyed("settings.choice.themeAccent", "Theme Accent")
            ),
            SettingDescriptor(
                ["notifications", "attention", "terminals"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.terminals", "Ring Terminal Panes"),
                kind: .choice(Self.ringLooks), default: .string(attention.terminalRing.rawValue),
                keywords: ["ring", "glow", "flash", "blink", "terminal"]
            ),
            SettingDescriptor(
                ["notifications", "attention", "agentChats"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.agentChats", "Ring Agent Chat Panes"),
                help: SettingsText.keyed("settings.attention.agentChats.help",
                                        "Ring an agent chat's pane when its turn ends, until you click or type in it."),
                kind: .choice(Self.ringLooks), default: .string(attention.agentChatRing.rawValue),
                keywords: ["ring", "glow", "flash", "blink", "agent", "chat", "turn"]
            ),
            SettingDescriptor(
                ["notifications", "attention", "agentChatBlinkCount"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.agentChatBlinkCount", "Agent Chat Blinks"),
                kind: .number(SettingNumber(Double(AttentionSettings.blinkRange.lowerBound)...Double(AttentionSettings.blinkRange.upperBound),
                                            step: 1, unit: .count)),
                default: .number(Double(attention.agentChatBlinkCount))
            ),
            SettingDescriptor(
                ["notifications", "attention", "width"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.width", "Width"),
                kind: .number(SettingsSchema.points(AttentionSettings.widthRange, step: 0.5)), default: .number(Double(attention.width))
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
                ["notifications", "attention", "flash"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.flash", "Flash the Pane When Read"),
                help: SettingsText.keyed("settings.attention.flash.help",
                                        "Clicking an unread pane, typing in it or jumping to it flashes its ring as it goes."),
                kind: .toggle, default: .bool(attention.flashesOnRead), keywords: ["ring", "flash", "blink", "unread"]
            ),
            SettingDescriptor(
                ["notifications", "attention", "flashOnTyping"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.flashOnTyping", "Flash When Typing Reads It"),
                kind: .toggle, default: .bool(attention.flashesOnTyping), keywords: ["ring", "flash", "keystroke", "unread"]
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
            SettingDescriptor(
                ["notifications", "attention", "moveToTop"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.moveToTop", "Move the Workspace to the Top"),
                help: SettingsText.keyed("settings.attention.moveToTop.help",
                                        "A notification moves its workspace to the top of the unpinned rows, unless you are looking at its pane."),
                kind: .toggle, default: .bool(attention.movesToTop), keywords: ["reorder", "sort", "bump"]
            ),
            SettingDescriptor(
                ["notifications", "attention", "moveToTopOnAgentFinish"], section: .notifications, group: ring,
                title: SettingsText.keyed("settings.attention.moveToTopOnAgentFinish", "Move the Workspace to the Top When Its Agent Finishes"),
                help: SettingsText.keyed("settings.attention.moveToTopOnAgentFinish.help",
                                        "An agent that finishes its turn moves its workspace to the top of the unpinned rows, unless you are looking at its pane."),
                kind: .toggle, default: .bool(attention.movesToTopOnAgentFinish), keywords: ["reorder", "sort", "bump", "agent", "done", "finished"]
            ),
            SettingDescriptor(
                ["notifications", "mutedWorkspaces"], section: .notifications, group: banners,
                title: SettingsText.keyed("settings.notifications.mutedWorkspaces", "Muted Workspaces"),
                help: SettingsText.keyed("settings.notifications.mutedWorkspaces.help",
                                        "Workspace ids whose notifications are silent. Mute a workspace from its sidebar row menu."),
                kind: .stringList, default: .array([]), keywords: ["mute", "silence"]
            )
            // Raw workspace ids mean nothing on the page; the sidebar row menu mutes a workspace.
            .hiddenFromSettingsPage("workspace ids; toggled per workspace from the sidebar row menu")
            .consumed(by: [.cmuxNext, .cmuxBrowser]),
        ]
        return rows
    }

    /// The attention ring's looks, per pane kind (`notifications.attention.terminals`, `agentChats`).
    static var ringLooks: [SettingChoice] {
        [
            SettingChoice(FocusRingStyle.glow.rawValue, SettingsText.keyed("settings.choice.glow", "Glow")),
            SettingChoice(FocusRingStyle.ring.rawValue, SettingsText.keyed("settings.choice.ring", "Ring")),
            SettingChoice(FocusRingStyle.none.rawValue, SettingsText.keyed("settings.choice.none", "None")),
        ]
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
