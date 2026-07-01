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
