import CmuxSettings
import SwiftUI

@MainActor
struct ModifierHoldHintsSettingsRow: View {
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints

    private var title: String {
        String(localized: "settings.shortcuts.showModifierHoldHints", defaultValue: "Show Shortcut Hints While Holding Modifier Keys")
    }

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("shortcuts.showModifierHoldHints"),
            title,
            subtitle: String(localized: "settings.shortcuts.showModifierHoldHints.subtitle", defaultValue: "Holding Command or Control shows shortcut hints.")
        ) {
            Toggle(isOn: $showModifierHoldHints) {
                EmptyView()
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsKeyboardShortcutsModifierHoldHintsToggle")
            .accessibilityLabel(title)
        }
    }
}
