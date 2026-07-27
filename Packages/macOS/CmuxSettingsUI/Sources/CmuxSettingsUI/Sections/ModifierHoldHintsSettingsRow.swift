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
            subtitle: showModifierHoldHints
                ? String(localized: "settings.shortcuts.showModifierHoldHints.subtitleOn", defaultValue: "Holding Cmd or Control shows shortcut hint chips.")
                : String(localized: "settings.shortcuts.showModifierHoldHints.subtitleOff", defaultValue: "Holding Cmd or Control does not show shortcut hint chips.")
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
