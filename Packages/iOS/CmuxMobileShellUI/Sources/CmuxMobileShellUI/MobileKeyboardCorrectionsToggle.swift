#if os(iOS)
import CmuxMobileTerminal
import SwiftUI

/// Settings row for the opt-in terminal keyboard correction behavior.
@MainActor
struct MobileKeyboardCorrectionsToggle: View {
    let preference: MobileTerminalKeyboardCorrectionPreference

    var body: some View {
        @Bindable var preference = preference
        Toggle(isOn: $preference.isEnabled) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(
                    "mobile.settings.keyboardCorrections",
                    defaultValue: "Autocomplete and Autocorrect"
                ))
                Text(L10n.string(
                    "mobile.settings.keyboardCorrectionsFooter",
                    defaultValue: "Allow iOS to suggest, autocorrect, and spell-check terminal input. Off by default because corrections can change commands."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("MobileSettingsKeyboardCorrectionsToggle")
    }
}
#endif
