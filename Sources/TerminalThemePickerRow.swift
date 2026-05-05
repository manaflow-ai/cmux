import Foundation
import SwiftUI

struct TerminalThemePickerRow: View {
    struct Option: Identifiable, Hashable {
        let id: String
        let title: String
        let mode: TerminalThemeMode
    }

    let configurationReview: SettingsConfigurationReview
    let searchAnchorID: String
    let selectedMode: TerminalThemeMode
    let availableThemeNames: [String]
    let onSelect: (TerminalThemeMode) -> Void

    private var selection: Binding<TerminalThemeMode> {
        Binding(
            get: { selectedMode },
            set: { onSelect($0) }
        )
    }

    private var adaptiveThemePair: (light: String, dark: String) {
        if case .adaptive(let light, let dark) = selectedMode {
            return (light, dark)
        }
        return (GhosttyConfig.cmuxDefaultLightThemeName, GhosttyConfig.cmuxDefaultDarkThemeName)
    }

    private var options: [Option] {
        var result = [
            Option(
                id: "custom",
                title: String(localized: "settings.app.terminalTheme.custom", defaultValue: "Custom (use my config)"),
                mode: .custom
            )
        ]
        var seenThemeNames = Set<String>()
        let adaptivePair = adaptiveThemePair

        result.append(
            Option(
                id: "adaptive:\(adaptivePair.light):\(adaptivePair.dark)",
                title: "\(String(localized: "settings.app.terminalTheme.adaptivePrefix", defaultValue: "Adaptive")): \(adaptivePair.light) / \(adaptivePair.dark)",
                mode: .adaptive(light: adaptivePair.light, dark: adaptivePair.dark)
            )
        )

        if case .named(let name) = selectedMode {
            appendNamedOption(name, to: &result, seenThemeNames: &seenThemeNames)
        }

        for name in availableThemeNames {
            appendNamedOption(name, to: &result, seenThemeNames: &seenThemeNames)
        }

        return result
    }

    private var subtitle: String {
        switch selectedMode {
        case .custom:
            return String(
                localized: "settings.app.terminalTheme.subtitleCustom",
                defaultValue: "Your Ghostty config controls terminal colors."
            )
        case .named:
            return String(
                localized: "settings.app.terminalTheme.subtitleNamed",
                defaultValue: "Terminal colors are set by the selected theme."
            )
        case .adaptive:
            return String(
                localized: "settings.app.terminalTheme.subtitleAdaptive",
                defaultValue: "Uses separate light and dark Ghostty themes."
            )
        }
    }

    init(
        configurationReview: SettingsConfigurationReview,
        searchAnchorID: String,
        selectedMode: TerminalThemeMode,
        availableThemeNames: [String],
        onSelect: @escaping (TerminalThemeMode) -> Void
    ) {
        configurationReview.validate()
        self.configurationReview = configurationReview
        self.searchAnchorID = searchAnchorID
        self.selectedMode = selectedMode
        self.availableThemeNames = availableThemeNames
        self.onSelect = onSelect
    }

    var body: some View {
        SettingsPickerRow(
            configurationReview: configurationReview,
            String(localized: "settings.app.terminalTheme", defaultValue: "Terminal Theme"),
            subtitle: subtitle,
            controlWidth: 240,
            selection: selection
        ) {
            ForEach(options) { option in
                Text(option.title).tag(option.mode)
            }
        }
        .settingsSearchAnchor(searchAnchorID)
    }

    private func appendNamedOption(
        _ name: String,
        to options: inout [Option],
        seenThemeNames: inout Set<String>
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard seenThemeNames.insert(folded).inserted else { return }
        options.append(
            Option(
                id: "named:\(trimmed)",
                title: trimmed,
                mode: .named(trimmed)
            )
        )
    }
}
