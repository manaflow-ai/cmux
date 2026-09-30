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

    /// Stroke color of the attention ring and pane flash, as a `#RRGGBB` hex.
    /// Empty (the default) uses the cmux accent (`app.accentColor`).
    public let paneFlashColorHex = DefaultsKey<String>(
        id: "notifications.paneFlashColor",
        defaultValue: "",
        userDefaultsKey: "notificationPaneFlashColorHex"
    )

    public let sound = DefaultsKey<String>(
        id: "notifications.sound",
        defaultValue: "default",
        userDefaultsKey: "notificationSound"
    )

    /// Plays the notification sound even when the notifying pane is already
    /// focused. Off by default: the focused pane shows the ring and flash only,
    /// since its "default" sound is the system alert that also marks errors.
    public let soundWhenFocused = DefaultsKey<Bool>(
        id: "notifications.soundWhenFocused",
        defaultValue: false,
        userDefaultsKey: "notificationSoundWhenFocused"
    )

    public let customSoundFilePath = DefaultsKey<String>(
        id: "notifications.customSoundFilePath",
        defaultValue: "",
        userDefaultsKey: "notificationSoundCustomFilePath"
    )

    /// Canonical JSON for the sparse agent × alert-type sound matrix. The
    /// string backing keeps cmux.json's nested object declarative while using
    /// the existing managed UserDefaults import/backup machinery.
    public let soundOverrides = DefaultsKey<String>(
        id: "notifications.soundOverrides",
        defaultValue: "{}",
        userDefaultsKey: "notificationSoundOverrides"
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

    /// When enabled, cmux skips the desktop banner for every notification while
    /// cmux is the active app, not only for the focused surface. The
    /// notification is still recorded, the sound and custom command still run,
    /// and phone forwarding keeps the focused-surface gate. Off keeps
    /// delivering banners for other workspaces and panes while cmux is
    /// focused. See issue #3126.
    public let suppressWhenAppFocused = DefaultsKey<Bool>(
        id: "notifications.suppressWhenAppFocused",
        defaultValue: false,
        userDefaultsKey: "notificationsSuppressWhenAppFocused"
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

    /// Catalog handle for the `notifications.hooks` path. The runtime reader
    /// is the app's notification config parser, which decodes an array of
    /// hook objects (`id`, `command`, `timeoutSeconds`, `enabled`); nothing
    /// reads this key's typed value.
    public let hooks = JSONKey<[String: String]>(
        id: "notifications.hooks",
        defaultValue: [:]
    )

    /// `"append"` (the runtime default when unset) adds project-local hooks
    /// after inherited ones; `"replace"` drops the inherited hooks first.
    public let hooksMode = JSONKey<String>(
        id: "notifications.hooksMode",
        defaultValue: "append"
    )

    public init() {}
}
