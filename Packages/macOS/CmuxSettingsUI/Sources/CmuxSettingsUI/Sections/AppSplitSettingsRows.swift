import CmuxSettings
import SwiftUI

/// Split sizing controls using the value models owned and observed by AppSection.
@MainActor
struct AppSplitSettingsRows: View {
    let equalizeSplitsOnCreate: DefaultsValueModel<Bool>
    let equalizeSplitsOnDividerDoubleClick: DefaultsValueModel<Bool>

    var body: some View {
        // Equalize Splits on Create
        SettingsCardRow(
            configurationReview: .json("app.equalizeSplitsOnCreate"),
            String(localized: "settings.app.equalizeSplitsOnCreate", defaultValue: "Equalize Splits on Create"),
            subtitle: String(localized: "settings.app.equalizeSplitsOnCreate.subtitle", defaultValue: "Splitting a pane makes the panes in that direction equal in size.")
        ) {
            Toggle("", isOn: Binding(
                get: { equalizeSplitsOnCreate.current },
                set: { equalizeSplitsOnCreate.set($0) }
            ))
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsEqualizeSplitsOnCreateToggle")
        }
        SettingsCardDivider()

        // Equalize Splits on Divider Double-Click
        SettingsCardRow(
            configurationReview: .json("app.equalizeSplitsOnDividerDoubleClick"),
            String(localized: "settings.app.equalizeSplitsOnDividerDoubleClick", defaultValue: "Equalize Splits on Divider Double-Click"),
            subtitle: String(localized: "settings.app.equalizeSplitsOnDividerDoubleClick.subtitle", defaultValue: "Double-clicking a divider makes the panes in its row or column equal in size.")
        ) {
            Toggle("", isOn: Binding(
                get: { equalizeSplitsOnDividerDoubleClick.current },
                set: { equalizeSplitsOnDividerDoubleClick.set($0) }
            ))
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsEqualizeSplitsOnDividerDoubleClickToggle")
        }
        SettingsCardDivider()
    }
}
