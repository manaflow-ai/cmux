import CmuxSettings
import Foundation

extension CommandPaletteSettingsToggleCommands {
    /// The palette toggle for `sidebar.clearReadNotificationMessage`, kept out
    /// of the length-budgeted descriptor table. It only matters while the
    /// notification message shows, so it hides with that row.
    static func sidebarClearReadNotificationMessageDescriptor(
        sectionTitle: @escaping @Sendable () -> String,
        isAvailable: @escaping @Sendable (UserDefaults) -> Bool
    ) -> CommandPaletteSettingToggleDescriptor {
        CommandPaletteSettingToggleDescriptor(
            commandId: commandIdPrefix + "clearReadNotificationMessageInSidebar",
            settingsKey: "sidebar.clearReadNotificationMessage",
            title: {
                String(localized: "settings.app.clearReadNotificationMessage", defaultValue: "Clear Notification Message Once Read")
            },
            sectionTitle: sectionTitle,
            keywords: ["sidebar.clearReadNotificationMessage", "sidebar", "notification", "message", "read", "unread", "clear"],
            defaultValue: SettingCatalog().sidebar.clearReadNotificationMessage.defaultValue,
            defaultsKey: SettingCatalog().sidebar.clearReadNotificationMessage.userDefaultsKey,
            isAvailable: { defaults in
                isAvailable(defaults)
                    && UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.showNotificationMessage)
            }
        )
    }
}
