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
