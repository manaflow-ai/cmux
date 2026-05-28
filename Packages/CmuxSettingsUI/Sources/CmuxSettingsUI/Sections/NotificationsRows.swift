import CmuxSettings
import SwiftUI

/// Legacy seam — kept so existing imports compile. The notification
/// rows are now embedded directly in ``AppSection`` so the new
/// `SettingsCard`-based chrome can wrap them in a single section
/// header. This type just renders a `SettingsCard` of the same rows
/// when callers want to embed them elsewhere.
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
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("Notifications")
            SettingsCard {
                toggleRow("Dock Badge",
                    subtitle: "Show the unread notification count on the cmux app icon.",
                    json: "notifications.dockBadge", key: catalog.notifications.dockBadge)
                SettingsCardDivider()
                toggleRow("Show Menu Bar Extra", subtitle: nil,
                    json: "notifications.showInMenuBar", key: catalog.notifications.showInMenuBar)
                SettingsCardDivider()
                toggleRow("Unread Pane Ring",
                    subtitle: "Outline panes with unread notifications in the workspace's color.",
                    json: "notifications.unreadPaneRing", key: catalog.notifications.unreadPaneRing)
                SettingsCardDivider()
                toggleRow("Pane Flash", subtitle: nil,
                    json: "notifications.paneFlash", key: catalog.notifications.paneFlash)
            }
        }
    }

    @ViewBuilder
    private func toggleRow(_ title: String, subtitle: String?, json: String, key: DefaultsKey<Bool>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle) {
            Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
    }
}
