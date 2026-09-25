import CmuxFoundation
import SwiftUI

/// Settings card for cmux's automatic Pi integration.
@MainActor
struct PiIntegrationCard: View {
    let isEnabled: Bool
    let setEnabled: (Bool) -> Void

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.piIntegration"),
                String(localized: "settings.automation.pi", defaultValue: "Pi Integration"),
                subtitle: isEnabled
                    ? String(localized: "settings.automation.pi.subtitleOn", defaultValue: "Sidebar shows Pi session status and notifications.")
                    : String(localized: "settings.automation.pi.subtitleOff", defaultValue: "Pi runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { isEnabled }, set: setEnabled))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsPiHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(
                localized: "settings.automation.pi.note",
                defaultValue: "When enabled, cmux wraps the pi command and loads its bundled session extension without changing your Pi configuration. Disable if you prefer to manage Pi hooks yourself."
            ))
        }
    }
}
