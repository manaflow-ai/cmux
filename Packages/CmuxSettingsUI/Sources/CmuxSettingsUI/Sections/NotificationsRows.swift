import CmuxSettings
import SwiftUI

/// Compact rows for the notification-related settings, hosted inside
/// the larger **App** section (where cmux's existing UI places them).
///
/// Covers the dock badge, menu-bar extra, unread-pane-ring, pane-flash
/// toggles plus the notification sound picker (with custom file path
/// + custom command escape hatches), a Send Test button so the user
/// can preview the configured sound, and an "Open System Notification
/// Settings" link.
@MainActor
public struct NotificationsRows: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog
    private let hostActions: SettingsHostActions?

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions? = nil
    ) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
        self.hostActions = hostActions
    }

    public var body: some View {
        Section("Notifications") {
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.dockBadge),
                title: "Dock Badge",
                subtitle: "Show the unread notification count on the cmux app icon in the Dock."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.showInMenuBar),
                title: "Show Menu Bar Extra"
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.unreadPaneRing),
                title: "Unread Pane Ring",
                subtitle: "Outline panes with unread notifications in the workspace's color."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.paneFlash),
                title: "Pane Flash"
            )
            if let hostActions {
                HStack {
                    Button("Request Permission") {
                        hostActions.requestNotificationAuthorization()
                    }
                    Button("Open System Notification Settings…") {
                        hostActions.openSystemNotificationSettings()
                    }
                    Spacer()
                    Button("Send Test") {
                        hostActions.sendTestNotification()
                    }
                }
            }
        }
        Section("Notification Sound") {
            SettingsDefaultsTextFieldRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.sound),
                title: "Sound",
                placeholder: "default | none | Frog | Glass | …",
                subtitle: "Name of an NSSound, the literal \"default\", \"none\", or \"custom\" to use the file path below."
            )
            SettingsDefaultsTextFieldRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.customSoundFilePath),
                title: "Custom Sound File",
                placeholder: "/path/to/sound.aiff",
                subtitle: "Used when Sound is set to \"custom\"."
            )
            SettingsDefaultsTextFieldRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.command),
                title: "Custom Notification Command",
                placeholder: "afplay /path/to/sound.wav",
                subtitle: "Optional shell command run on every notification. Leave empty to skip."
            )
        }
    }
}
