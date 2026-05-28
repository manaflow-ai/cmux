import CmuxSettings
import SwiftUI

/// Compact rows for the notification-related settings, hosted inside
/// the larger **App** section (where cmux's existing UI places them).
public struct NotificationsRows: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        Group {
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.dockBadge),
                title: "Dock badge",
                subtitle: "Show the unread notification count on the cmux app icon in the Dock."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.showInMenuBar),
                title: "Show menu bar extra"
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.unreadPaneRing),
                title: "Unread pane ring",
                subtitle: "Outline panes with unread notifications in the workspace's color."
            )
            SettingsToggleRow(
                model: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.paneFlash),
                title: "Pane flash"
            )
        }
    }
}
