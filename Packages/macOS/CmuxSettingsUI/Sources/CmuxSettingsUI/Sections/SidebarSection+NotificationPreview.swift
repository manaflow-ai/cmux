import CmuxSettings
import SwiftUI

extension SidebarSection {
    /// The rows that tune the notification message under each workspace title.
    @ViewBuilder
    var notificationPreviewRows: some View {
        clearReadNotificationMessageRow
        SettingsCardDivider()

        notificationMessageLineLimitRow
    }

    private var clearReadNotificationMessageRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.clearReadNotificationMessage"),
            String(localized: "settings.app.clearReadNotificationMessage", defaultValue: "Clear Notification Message Once Read"),
            subtitle: String(localized: "settings.app.clearReadNotificationMessage.subtitle", defaultValue: "Hide the notification message after you view the workspace or the request is resolved. When off, the latest message stays until you clear it.")
        ) {
            Toggle("", isOn: Binding(get: { clearReadNotification.current }, set: { clearReadNotification.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        .disabled(hideAll.current || !showNotification.current)
    }

    private var notificationMessageLineLimitRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.notificationMessageLineLimit"),
            String(localized: "settings.app.notificationMessageLineLimit", defaultValue: "Notification Preview Lines"),
            subtitle: String(localized: "settings.app.notificationMessageLineLimit.subtitle", defaultValue: "Maximum lines shown for the latest notification below each workspace title."),
            controlWidth: 100
        ) {
            Stepper(
                "\(notificationMessageLineLimit.current)",
                value: Binding(get: { notificationMessageLineLimit.current }, set: { notificationMessageLineLimit.set($0) }),
                in: SidebarCatalogSection.notificationMessageLineLimitRange
            )
            .accessibilityIdentifier("SettingsSidebarNotificationMessageLineLimitStepper")
            .accessibilityLabel(
                String(localized: "settings.app.notificationMessageLineLimit", defaultValue: "Notification Preview Lines")
            )
        }
        .disabled(hideAll.current || !showNotification.current)
    }
}
