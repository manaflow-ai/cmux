#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI

/// Settings row for the opt-in terminal keyboard correction behavior.
@MainActor
struct MobileKeyboardCorrectionsToggle: View {
    /// Snapshot of the persisted setting supplied by the owning settings view.
    let isEnabled: Bool
    /// Applies a setting change at the owning view boundary.
    let setEnabled: (Bool) -> Void

    /// Builds the settings row without retaining an observable store in the Form subtree.
    var body: some View {
        Toggle(isOn: Binding(get: { isEnabled }, set: setEnabled)) {
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
