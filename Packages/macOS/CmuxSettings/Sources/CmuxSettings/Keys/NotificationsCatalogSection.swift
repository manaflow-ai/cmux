import Foundation

/// Settings under the dotted-id prefix `notifications.*`.
public struct NotificationsCatalogSection: SettingCatalogSection {
    public let dockBadge = DefaultsKey<Bool>(
        id: "notifications.dockBadge",
        defaultValue: true,
        userDefaultsKey: "notificationDockBadgeEnabled"
    )

    public let showInMenuBar = DefaultsKey<Bool>(
        id: "notifications.showInMenuBar",
        defaultValue: true,
        userDefaultsKey: "showMenuBarExtra"
    )

    public let unreadPaneRing = DefaultsKey<Bool>(
        id: "notifications.unreadPaneRing",
        defaultValue: true,
        userDefaultsKey: "notificationPaneRingEnabled"
    )

    public let paneFlash = DefaultsKey<Bool>(
        id: "notifications.paneFlash",
        defaultValue: true,
        userDefaultsKey: "notificationPaneFlashEnabled"
    )

    public let sound = DefaultsKey<String>(
        id: "notifications.sound",
        defaultValue: "default",
        userDefaultsKey: "notificationSound"
    )

    public let customSoundFilePath = DefaultsKey<String>(
        id: "notifications.customSoundFilePath",
        defaultValue: "",
        userDefaultsKey: "notificationSoundCustomFilePath"
    )

    public let command = DefaultsKey<String>(
        id: "notifications.command",
        defaultValue: "",
        userDefaultsKey: "notificationCustomCommand"
    )

    /// When enabled, the implicit notification auto-withdraw fires only for the
    /// exact focused surface, so a banner delivered for a non-focused surface in
    /// the currently visible workspace is not retroactively withdrawn when the
    /// workspace becomes visible/active. Off preserves the legacy
    /// workspace-visibility withdraw. See issue #6601.
    public let suppressOnlyFocusedSurface = DefaultsKey<Bool>(
        id: "notifications.suppressOnlyFocusedSurface",
        defaultValue: false,
        userDefaultsKey: "notificationsSuppressOnlyFocusedSurface"
    )

    /// Notify when an agent (e.g. Claude Code) is blocked waiting for the user's
    /// permission to run a tool. On by default: this is the one alert the user
    /// must act on to unblock the agent.
    public let agentPermissionPrompt = DefaultsKey<Bool>(
        id: "notifications.agentPermissionPrompt",
        defaultValue: true,
        userDefaultsKey: "notificationAgentPermissionPromptEnabled"
    )

    /// When to notify that an agent finished a turn. `whenIdle` (default)
    /// suppresses the "done" notification while the agent still has a running
    /// background task or a pending scheduled wakeup, so you are only pinged once
    /// work truly drains. `always` notifies on every turn end; `never` never does.
    /// Raw values: `whenIdle` | `always` | `never`.
    public let agentTurnComplete = DefaultsKey<String>(
        id: "notifications.agentTurnComplete",
        defaultValue: "whenIdle",
        userDefaultsKey: "notificationAgentTurnComplete"
    )

    /// Notify when an agent has been idle-waiting for input (~60s after a turn
    /// ends). Suppressed while background work from the last turn is still
    /// pending, so a running build or watcher does not trigger a false "waiting".
    public let agentIdleReminder = DefaultsKey<Bool>(
        id: "notifications.agentIdleReminder",
        defaultValue: true,
        userDefaultsKey: "notificationAgentIdleReminderEnabled"
    )

    public let hooks = JSONKey<[String: String]>(
        id: "notifications.hooks",
        defaultValue: [:]
    )

    public let hooksMode = JSONKey<String>(
        id: "notifications.hooksMode",
        defaultValue: "merge"
    )

    public init() {}
}
