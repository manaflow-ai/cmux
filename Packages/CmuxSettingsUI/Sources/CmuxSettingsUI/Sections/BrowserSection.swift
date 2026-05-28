import AppKit
import CmuxSettings
import SwiftUI

/// **Browser** section.
@MainActor
public struct BrowserSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog
    private let hostActions: SettingsHostActions?

    @State private var confirmClearHistory: Bool = false

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions? = nil
    ) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
        self.hostActions = hostActions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("Browser")
            SettingsCard {
                toggleRow("Disable cmux Browser",
                    subtitle: "Routes every web URL to the system default browser.",
                    json: "browser.disabled", key: catalog.browser.disabled)
            }

            SettingsSectionHeader("Search")
            SettingsCard {
                pickerRow("Default Search Engine",
                    json: "browser.defaultSearchEngine",
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.browser.defaultSearchEngine),
                    cases: BrowserSearchEngine.allCases,
                    label: searchEngineLabel)
                SettingsCardDivider()
                toggleRow("Show Search Suggestions", subtitle: nil,
                    json: "browser.showSearchSuggestions", key: catalog.browser.showSearchSuggestions)
                SettingsCardDivider()
                textRow("Custom Search Engine Name", subtitle: nil,
                    placeholder: "My Engine",
                    json: "browser.customSearchEngineName", key: catalog.browser.customSearchEngineName)
                SettingsCardDivider()
                textRow("Custom Search Engine URL Template",
                    subtitle: "Use {query} as the placeholder.",
                    placeholder: "https://example.com/search?q={query}",
                    json: "browser.customSearchEngineURLTemplate", key: catalog.browser.customSearchEngineURLTemplate)
            }

            SettingsSectionHeader("Appearance")
            SettingsCard {
                pickerRow("Web Content Theme",
                    json: "browser.theme",
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.browser.theme),
                    cases: BrowserThemeMode.allCases,
                    label: { $0 == .system ? "Follow System" : ($0 == .light ? "Light" : "Dark") })
            }

            SettingsSectionHeader("Memory")
            SettingsCard {
                toggleRow("Discard Hidden Web Views",
                    subtitle: "Unload background tabs after they have been hidden for a while to save memory.",
                    json: "browser.discardHiddenWebViews", key: catalog.browser.discardHiddenWebViews)
                SettingsCardDivider()
                doubleStepperRow("Hidden WebView Discard Delay",
                    subtitle: nil,
                    json: "browser.hiddenWebViewDiscardDelaySeconds",
                    key: catalog.browser.hiddenWebViewDiscardDelaySeconds,
                    range: 5...3_600, step: 5,
                    format: { "\(Int($0))s" })
            }

            SettingsSectionHeader("Link Routing")
            SettingsCard {
                toggleRow("Open Terminal Links in cmux Browser", subtitle: nil,
                    json: "browser.openTerminalLinksInCmuxBrowser", key: catalog.browser.openTerminalLinksInCmuxBrowser)
                SettingsCardDivider()
                toggleRow("Intercept `open` http(s) in Terminal", subtitle: nil,
                    json: "browser.interceptTerminalOpenCommandInCmuxBrowser",
                    key: catalog.browser.interceptTerminalOpenCommandInCmuxBrowser)
                SettingsCardDivider()
                toggleRow("Show Import Hint on Blank Tabs", subtitle: nil,
                    json: "browser.showImportHintOnBlankTabs", key: catalog.browser.showImportHintOnBlankTabs)
            }

            if let hostActions {
                SettingsSectionHeader("History")
                SettingsCard {
                    SettingsCardRow(configurationReview: .action, "Browsing History",
                        subtitle: "Remove visited-page suggestions from the browser omnibar.") {
                        Button("Clear History…", role: .destructive) {
                            confirmClearHistory = true
                        }
                        .controlSize(.small)
                    }
                }
                .confirmationDialog(
                    "Clear browser history?",
                    isPresented: $confirmClearHistory,
                    titleVisibility: .visible
                ) {
                    Button("Clear History", role: .destructive) { hostActions.clearBrowserHistory() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes visited-page suggestions from the browser omnibar.")
                }
            }

            SettingsSectionHeader("Hostname Patterns")
            SettingsCard {
                multilineRow("Hosts to Open in Embedded Browser",
                    subtitle: "Newline-delimited host patterns. `*.example.com` matches all subdomains.",
                    json: "browser.hostsToOpenInEmbeddedBrowser",
                    key: catalog.browser.hostsToOpenInEmbeddedBrowser)
                SettingsCardDivider()
                multilineRow("URLs to Always Open Externally",
                    subtitle: "Newline-delimited URL patterns matched before any in-app routing.",
                    json: "browser.urlsToAlwaysOpenExternally",
                    key: catalog.browser.urlsToAlwaysOpenExternally)
                SettingsCardDivider()
                multilineRow("HTTP Hosts Allowed in Embedded Browser",
                    subtitle: "Hosts cmux's embedded browser may load over plain HTTP. Use sparingly.",
                    json: "browser.insecureHttpHostsAllowedInEmbeddedBrowser",
                    key: catalog.browser.insecureHttpHostsAllowedInEmbeddedBrowser)
            }
        }
    }

    @ViewBuilder
    private func toggleRow(_ title: String, subtitle: String?, json: String, key: DefaultsKey<Bool>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle) {
            Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func textRow(_ title: String, subtitle: String?, placeholder: String, json: String, key: DefaultsKey<String>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle, controlWidth: 240) {
            TextField(placeholder, text: Binding(get: { model.current }, set: { model.set($0) }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func pickerRow<Value: SettingCodable & Hashable & CaseIterable>(
        _ title: String,
        json: String,
        model: DefaultsValueModel<Value>,
        cases: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        SettingsCardRow(configurationReview: .json(json), title, controlWidth: 200) {
            Picker("", selection: Binding(get: { model.current }, set: { model.set($0) })) {
                ForEach(cases, id: \.self) { value in Text(label(value)).tag(value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private func doubleStepperRow(_ title: String, subtitle: String?, json: String, key: DefaultsKey<Double>, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle, controlWidth: 140) {
            Stepper(value: Binding(get: { model.current }, set: { model.set($0) }), in: range, step: step) {
                Text(format(model.current)).monospacedDigit()
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func multilineRow(_ title: String, subtitle: String?, json: String, key: DefaultsKey<String>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle) {
            EmptyView()
        }
        TextEditor(text: Binding(get: { model.current }, set: { model.set($0) }))
            .frame(minHeight: 70, maxHeight: 140)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
    }

    private func searchEngineLabel(_ engine: BrowserSearchEngine) -> String {
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
}
