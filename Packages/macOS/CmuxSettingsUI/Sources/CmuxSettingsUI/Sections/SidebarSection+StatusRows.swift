import CmuxSettings
import SwiftUI

extension SidebarSection {
    var statusEntryLimitRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.statusEntryLimit"),
            String(localized: "settings.app.statusEntryLimit", defaultValue: "Sidebar Status Rows"),
            subtitle: String(localized: "settings.app.statusEntryLimit.subtitle", defaultValue: "Maximum status rows shown before Show more. Set to 0 to keep all status rows visible."),
            controlWidth: 100
        ) {
            Stepper(
                statusEntryLimit.current == 0
                    ? String(localized: "settings.app.statusEntryLimit.all", defaultValue: "All")
                    : "\(statusEntryLimit.current)",
                value: Binding(get: { statusEntryLimit.current }, set: { statusEntryLimit.set($0) }),
                in: SidebarCatalogSection.statusEntryLimitRange
            )
            .accessibilityIdentifier("SettingsSidebarStatusEntryLimitStepper")
            .accessibilityLabel(
                String(localized: "settings.app.statusEntryLimit", defaultValue: "Sidebar Status Rows")
            )
        }
        .disabled(hideAll.current || !showMetadata.current)
    }
}
