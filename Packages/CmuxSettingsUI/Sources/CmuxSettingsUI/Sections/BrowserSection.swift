import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Browser** section.
///
/// Search engine, theme, search suggestions, hidden-webview discard
/// behavior, and the cmux-vs-system link-routing toggles. Free-form
/// hostname patterns are exposed via single-line text fields backed by
/// UserDefaults strings (newline-delimited in the underlying value, as
/// cmux's existing UI does today).
public struct BrowserSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section("Search") {
                SettingsPickerRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.browser.defaultSearchEngine),
                    title: "Default search engine",
                    label: { engine in
                        switch engine {
                        case .google: return "Google"
                        case .duckduckgo: return "DuckDuckGo"
                        case .bing: return "Bing"
                        case .kagi: return "Kagi"
                        case .startpage: return "Startpage"
                        case .brave: return "Brave"
                        case .perplexity: return "Perplexity"
                        case .exa: return "Exa"
                        case .yahoo: return "Yahoo"
                        case .ecosia: return "Ecosia"
                        case .qwant: return "Qwant"
                        case .mojeek: return "Mojeek"
                        case .wikipedia: return "Wikipedia"
                        case .github: return "GitHub"
                        case .baidu: return "Baidu"
                        case .yandex: return "Yandex"
                        case .custom: return "Custom"
                        }
                    }
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.browser.showSearchSuggestions),
                    title: "Show search suggestions"
                )
            }
            Section("Appearance") {
                SettingsPickerRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.browser.theme),
                    title: "Web content theme",
                    label: { theme in
                        switch theme {
                        case .system: return "Follow System"
                        case .light: return "Light"
                        case .dark: return "Dark"
                        }
                    }
                )
            }
            Section("Memory") {
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.browser.discardHiddenWebViews),
                    title: "Discard hidden web views",
                    subtitle: "Unload background tabs after they have been hidden for a while to save memory."
                )
            }
            Section("Link routing") {
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.browser.openTerminalLinksInCmuxBrowser),
                    title: "Open terminal links in cmux browser"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.browser.interceptTerminalOpenCommandInCmuxBrowser),
                    title: "Intercept `open` http(s) in terminal"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.browser.showImportHintOnBlankTabs),
                    title: "Show import hint on blank tabs"
                )
            }
        }
        .formStyle(.grouped)
    }
}
