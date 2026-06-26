import CmuxSettings
import SwiftUI

@MainActor
struct CommandHoldHintsSettingsRow: View {
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @LiveSetting(\.shortcuts.showCommandHoldHints) private var showCommandHoldHints

    private var title: String {
        String(localized: "settings.shortcuts.showCommandHoldHints", defaultValue: "Show Shortcut Hints While Holding Cmd")
    }

    private var subtitle: String {
        if !showModifierHoldHints {
            return String(
                localized: "settings.shortcuts.showCommandHoldHints.subtitleMasterOff",
                defaultValue: "Modifier-key shortcut hints are turned off."
            )
        }
        if showCommandHoldHints {
            return String(
                localized: "settings.shortcuts.showCommandHoldHints.subtitleOn",
                defaultValue: "Holding Cmd shows shortcut hint chips."
            )
        }
        return String(
            localized: "settings.shortcuts.showCommandHoldHints.subtitleOff",
            defaultValue: "Holding Cmd does not show shortcut hint chips."
        )
    }

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("shortcuts.showCommandHoldHints"),
            title,
            subtitle: subtitle
        ) {
            Toggle(isOn: $showCommandHoldHints) {
                EmptyView()
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsKeyboardShortcutsCommandHoldHintsToggle")
            .accessibilityLabel(title)
        }
    }
}
