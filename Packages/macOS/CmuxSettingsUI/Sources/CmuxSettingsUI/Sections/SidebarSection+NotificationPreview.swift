import CmuxSettings
import SwiftUI

extension SidebarSection {
    var notificationMessageLineLimitRow: some View {
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
