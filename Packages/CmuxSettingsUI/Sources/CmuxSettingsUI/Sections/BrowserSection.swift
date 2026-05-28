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
            Section("Browser") {
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.browser.disabled),
                    title: "Disable cmux browser",
                    subtitle: "Routes every web URL to the system default browser. cmux's embedded browser becomes inaccessible."
                )
            }
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
                SettingsDefaultsTextFieldRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.browser.customSearchEngineName),
                    title: "Custom search engine name"
                )
                SettingsDefaultsTextFieldRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.browser.customSearchEngineURLTemplate),
                    title: "Custom search engine URL template",
                    placeholder: "https://example.com/search?q={query}"
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
            Section("Hostname Patterns") {
                multilineRow(
                    title: "Hosts to open in cmux browser",
                    subtitle: "Newline-delimited host patterns. `*.example.com` matches all subdomains.",
                    key: catalog.browser.hostsToOpenInEmbeddedBrowser
                )
                multilineRow(
                    title: "URLs to always open externally",
                    subtitle: "Newline-delimited URL patterns matched before any in-app routing.",
                    key: catalog.browser.urlsToAlwaysOpenExternally
                )
                multilineRow(
                    title: "Hosts allowed over insecure HTTP",
                    subtitle: "Hosts cmux's embedded browser may load over plain HTTP. Use sparingly.",
                    key: catalog.browser.insecureHttpHostsAllowedInEmbeddedBrowser
                )
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func multilineRow(title: String, subtitle: String, key: DefaultsKey<String>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { model.current },
                set: { model.set($0) }
            ))
            .frame(minHeight: 70, maxHeight: 140)
            .font(.system(.body, design: .monospaced))
            .border(Color(nsColor: .separatorColor))
        }
    }
}
