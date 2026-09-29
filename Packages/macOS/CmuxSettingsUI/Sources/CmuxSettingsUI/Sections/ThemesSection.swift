import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Themes** section: every color and appearance setting in one place.
/// App appearance, accent color and app icon, the browser page theme, the adaptive
/// default theme toggle, and the terminal theme gallery with every theme
/// Ghostty ships.
@MainActor
public struct ThemesSection: View {
    private let hostActions: SettingsHostActions

    @State private var appearance: DefaultsValueModel<AppearanceMode>
    @State private var accentColor: DefaultsValueModel<CmuxAccentColorMode>
    @State private var appIcon: DefaultsValueModel<AppIconMode>
    @State private var adaptiveDefaultTheme: DefaultsValueModel<Bool>
    @State private var browserTheme: DefaultsValueModel<BrowserThemeMode>

    private static let columnWidth: CGFloat = 196

    /// Creates the Themes settings section.
    ///
    /// - Parameters:
    ///   - defaultsStore: The store used to read and write theme settings.
    ///   - catalog: The catalog that provides the theme-related setting keys.
    ///   - hostActions: Host callbacks for the terminal theme gallery and reloads.
    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog, hostActions: SettingsHostActions) {
        self.hostActions = hostActions
        _appearance = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.appearance))
        _accentColor = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.accentColor))
        _appIcon = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.appIcon))
        _adaptiveDefaultTheme = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.adaptiveDefaultTheme))
        _browserTheme = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.theme))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.themes", defaultValue: "Themes"), section: .themes)
            appCard
            SettingsCard {
                browserThemeRow
            }
            // Last: the gallery lists every theme and runs long.
            SettingsCard {
                adaptiveDefaultThemeRow
                SettingsCardDivider()
                TerminalThemeSettingsRows(hostActions: hostActions)
            }
        }
        .task { startSettingsObservation([appearance, accentColor, appIcon, adaptiveDefaultTheme, browserTheme]) }
    }

    @ViewBuilder
    private var appCard: some View {
        SettingsCard {
            ThemePickerRow(
                selectedMode: appearance.current,
                onSelect: { appearance.set($0) }
            )
            .settingsSearchAnchors(["setting:themes:appearance"])
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("app.accentColor"),
                String(localized: "settings.app.accentColor", defaultValue: "Accent Color"),
                subtitle: String(localized: "settings.app.accentColor.subtitle", defaultValue: "Color of the selected workspace, attention ring, agent status, and other cmux highlights. System follows the macOS accent color."),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { accentColor.current }, set: { accentColor.set($0) })) {
                    Text(String(localized: "settings.app.accentColor.cmux", defaultValue: "cmux Blue")).tag(CmuxAccentColorMode.cmux)
                    Text(String(localized: "settings.app.accentColor.system", defaultValue: "System")).tag(CmuxAccentColorMode.system)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("SettingsAccentColorPicker")
            }
            SettingsCardDivider()
            // Also under App. Both rows bind the same key and update each
            // other; search lands on the App row, so this one has no anchor.
            AppIconPickerRow(
                selectedMode: appIcon.current,
                onSelect: { appIcon.set($0) }
            )
        }
    }

    private var adaptiveDefaultThemeRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.adaptiveDefaultTheme"),
            String(
                localized: "settings.terminal.adaptiveDefaultTheme",
                defaultValue: "Adapt Default Theme to Appearance"
            ),
            subtitle: String(localized: "settings.terminal.adaptiveDefaultTheme.subtitle", defaultValue: "Matches terminal colors to the light or dark appearance when no Ghostty theme or colors are set.")
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { adaptiveDefaultTheme.current },
                    set: { enabled in
                        adaptiveDefaultTheme.set(enabled) {
                            @MainActor [hostActions] in
                            hostActions.terminalAdaptiveDefaultThemeDidChange()
                        }
                    }
                )
            )
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsTerminalAdaptiveDefaultThemeToggle")
        }
    }

    private var browserThemeRow: some View {
        SettingsCardRow(
            configurationReview: .json("browser.theme"),
            String(localized: "settings.browser.theme", defaultValue: "Browser Theme"),
            subtitle: String(localized: "settings.browser.theme.subtitle", defaultValue: "Choose light or dark pages for sites that support both. System matches the app appearance."),
            controlWidth: Self.columnWidth
        ) {
            Picker("", selection: Binding(get: { browserTheme.current }, set: { browserTheme.set($0) })) {
                ForEach(BrowserThemeMode.allCases, id: \.self) { mode in
                    Text(Self.browserThemeDisplayName(mode)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private static func browserThemeDisplayName(_ mode: BrowserThemeMode) -> String {
        switch mode {
        case .system:
            return String(localized: "theme.system", defaultValue: "System")
        case .light:
            return String(localized: "theme.light", defaultValue: "Light")
        case .dark:
            return String(localized: "theme.dark", defaultValue: "Dark")
        }
    }
}
