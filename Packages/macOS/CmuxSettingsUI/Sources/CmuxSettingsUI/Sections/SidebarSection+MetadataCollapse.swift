import SwiftUI

extension SidebarSection {
    var metadataCollapseLimitRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebarAppearance.metadataCollapseLimit"),
            String(localized: "settings.app.metadataCollapseLimit", defaultValue: "Metadata Collapse Limit"),
            subtitle: String(
                localized: "settings.app.metadataCollapseLimit.subtitle",
                defaultValue: "Number of custom metadata entries shown before Show more. Set to 0 to always show all entries."
            ),
            controlWidth: 100
        ) {
            Stepper(
                value: Binding(
                    get: { metadataCollapseLimit.current },
                    set: { metadataCollapseLimit.set($0) }
                ),
                in: 0...Int.max
            ) {
                Text(
                    metadataCollapseLimit.current == 0
                        ? String(localized: "settings.app.metadataCollapseLimit.unlimited", defaultValue: "Unlimited")
                        : metadataCollapseLimit.current.formatted(.number.grouping(.never))
                )
                .monospacedDigit()
            }
            .accessibilityIdentifier("SettingsSidebarMetadataCollapseLimitStepper")
            .accessibilityLabel(
                String(localized: "settings.app.metadataCollapseLimit", defaultValue: "Metadata Collapse Limit")
            )
        }
        .disabled(hideAll.current || !showMetadata.current)
    }
}
