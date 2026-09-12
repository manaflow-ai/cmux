import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Chrome** settings — the named palette and per-token overrides used by
/// cmux-owned sidebar/tab-strip chrome. The selected theme follows the
/// existing App appearance mode (System/Light/Dark).
@MainActor
public struct ChromeSection: View {
    @State private var theme: JSONValueModel<ChromeThemeID>
    @State private var overrides: JSONValueModel<ChromeTokenOverrides>
    @State private var drafts: ChromeTokenOverrideDrafts
    @Environment(\.chromePalette) private var chromePalette

    public init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog
    ) {
        let themeModel = JSONValueModel(
            store: jsonStore,
            key: catalog.chrome.theme,
            errorLog: errorLog
        )
        let overridesModel = JSONValueModel(
            store: jsonStore,
            key: catalog.chrome.overrides,
            errorLog: errorLog
        )
        _theme = State(initialValue: themeModel)
        _overrides = State(initialValue: overridesModel)
        _drafts = State(initialValue: ChromeTokenOverrideDrafts(overrides: overridesModel.current))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.chrome", defaultValue: "Chrome"),
                section: .chrome
            )
            SettingsCard {
                themeRow
                SettingsCardDivider()
                SettingsCardNote(
                    String(
                        localized: "settings.chrome.note",
                        defaultValue: "Chrome themes apply to the sidebar, tab strip, agent surfaces, and notification accents. System appearance selects each theme's light or dark variant."
                    )
                )
                SettingsCardDivider()
                SettingsCardNote(
                    String(
                        localized: "settings.chrome.overrides.title",
                        defaultValue: "Token overrides"
                    )
                )
                ForEach(ChromeToken.allCases, id: \.self) { token in
                    SettingsCardDivider()
                    tokenRow(token)
                }
                SettingsCardDivider()
                SettingsCardNote(
                    String(
                        localized: "settings.chrome.followTerminalTheme.followUp",
                        defaultValue: "Following the active terminal theme is planned as a future enhancement."
                    )
                )
            }
        }
        .task {
            theme.startObserving()
            overrides.startObserving()
        }
        .onChange(of: overrides.current) { _, value in
            drafts.synchronize(with: value)
        }
    }

    @ViewBuilder
    private var themeRow: some View {
        SettingsCardRow(
            configurationReview: .json("chrome.theme"),
            searchAnchorID: "setting:chrome:theme",
            String(localized: "settings.chrome.theme", defaultValue: "Chrome Theme"),
            subtitle: String(
                localized: "settings.chrome.theme.subtitle",
                defaultValue: "Choose a built-in palette. Light and dark variants follow the App appearance setting."
            ),
            controlWidth: 196
        ) {
            Picker("", selection: Binding(
                get: { theme.current },
                set: { theme.set($0) }
            )) {
                ForEach(ChromeThemeID.allCases, id: \.self) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("SettingsChromeThemePicker")
        }
    }

    @ViewBuilder
    private func tokenRow(_ token: ChromeToken) -> some View {
        let currentValue = drafts[token]
        SettingsCardRow(
            // The override editor is one logical setting even though it has a
            // field for each token. Anchor only the first field so search
            // navigation never creates duplicate SwiftUI ids for the other
            // token rows.
            configurationReview: token == ChromeToken.allCases.first
                ? .json("chrome.overrides")
                : .action,
            searchAnchorID: token == ChromeToken.allCases.first
                ? "setting:chrome:token-overrides"
                : nil,
            token.displayName,
            subtitle: String(
                localized: "settings.chrome.token.subtitle",
                defaultValue: "Optional #RRGGBB or #RRGGBBAA override. Leave empty to use the selected theme."
            ),
            controlWidth: 260
        ) {
            HStack(spacing: 6) {
                if let color = ChromeColor(hex: currentValue) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
                        .frame(width: 18, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(
                            Color(red: chromePalette.border.red, green: chromePalette.border.green, blue: chromePalette.border.blue, opacity: chromePalette.border.alpha)
                                .opacity(0.6)
                        ))
                }
                TextField(
                    String(localized: "settings.chrome.token.placeholder", defaultValue: "Theme default"),
                    text: Binding(
                        get: { drafts[token] },
                        set: { drafts.edit($0, for: token) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 134)
                .onSubmit { commit(token) }
                Button(String(localized: "settings.chrome.token.apply", defaultValue: "Apply")) {
                    commit(token)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(String(localized: "settings.chrome.token.reset", defaultValue: "Reset")) {
                    drafts.edit("", for: token)
                    commit(token)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .help(drafts.isInvalid(token)
                ? String(localized: "settings.chrome.token.invalid", defaultValue: "Enter a six- or eight-digit hexadecimal color.")
                : String(localized: "settings.chrome.token.help", defaultValue: "Set a custom color for this token."))
        }
    }

    private func commit(_ token: ChromeToken) {
        let raw = drafts.trimmedValue(for: token)
        if raw.isEmpty {
            drafts.stageCanonicalValue("", for: token)
            overrides.update { current in
                var values = current.values
                values.removeValue(forKey: token)
                return ChromeTokenOverrides(values)
            }
            return
        }
        guard let color = ChromeColor(hex: raw) else {
            drafts.markInvalid(token)
            return
        }
        drafts.stageCanonicalValue(color.hex, for: token)
        overrides.update { current in
            var values = current.values
            values[token] = color
            return ChromeTokenOverrides(values)
        }
    }
}
