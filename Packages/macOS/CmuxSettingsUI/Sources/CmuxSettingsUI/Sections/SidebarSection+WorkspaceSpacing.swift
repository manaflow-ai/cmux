import CmuxSettings
import SwiftUI

extension SidebarSection {
    var workspaceSpacingRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.workspaceSpacing"),
            String(
                localized: "settings.sidebarAppearance.workspaceSpacing",
                defaultValue: "Workspace Spacing"
            ),
            subtitle: String(
                localized: "settings.sidebarAppearance.workspaceSpacing.subtitle",
                defaultValue: "Controls the space between workspace and group rows."
            ),
            controlWidth: 100
        ) {
            Stepper(
                String.localizedStringWithFormat(
                    String(localized: "settings.fontSize.valuePoints", defaultValue: "%@ pt"),
                    String(workspaceSpacing.current)
                ),
                value: Binding(
                    get: { workspaceSpacing.current },
                    set: { workspaceSpacing.set($0) }
                ),
                in: SidebarCatalogSection.workspaceSpacingRange
            )
            .accessibilityIdentifier("SettingsSidebarWorkspaceSpacingStepper")
            .accessibilityLabel(
                String(
                    localized: "settings.sidebarAppearance.workspaceSpacing",
                    defaultValue: "Workspace Spacing"
                )
            )
        }
    }
}
