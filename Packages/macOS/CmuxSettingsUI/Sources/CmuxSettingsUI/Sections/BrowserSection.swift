import CmuxFoundation
import AppKit
import CmuxSettings
import SwiftUI

/// **Browser** section — mirrors the legacy in-app section
/// row-for-row inside a single `SettingsCard`: Enable cmux Browser,
/// Default Search Engine, conditional Custom Search Engine fields,
/// Show Search Suggestions, Browser Theme, Browser Memory Saver +
/// Memory Saver Delay, Open Terminal Links / Intercept open,
/// conditional Hosts / External Patterns text editors, HTTP Hosts
/// Allowed in Embedded Browser editor, Import Browser Data
/// subsection, React Grab Version, Browsing History.
@MainActor
public struct BrowserSection: View {
    private let catalog: SettingCatalog
    private let hostActions: SettingsHostActions
    private let importAnchorID: String?

    @State private var disabled: DefaultsValueModel<Bool>
    @State private var engine: DefaultsValueModel<BrowserSearchEngine>
    @State private var customName: DefaultsValueModel<String>
    @State private var customURL: DefaultsValueModel<String>
    @State private var suggestions: DefaultsValueModel<Bool>
    @State private var theme: DefaultsValueModel<BrowserThemeMode>
    @State private var discardEnabled: DefaultsValueModel<Bool>
    @State private var discardDelay: DefaultsValueModel<Double>
    @State private var askWhereToSaveDownloads: DefaultsValueModel<Bool>
    @State private var openTermLinks: DefaultsValueModel<Bool>
    @State private var interceptOpen: DefaultsValueModel<Bool>
    @State private var hosts: DefaultsValueModel<String>
    @State private var external: DefaultsValueModel<String>
    @State private var httpAllowlist: DefaultsValueModel<String>
    @State private var importHint: DefaultsValueModel<Bool>
    @State private var reactGrab: DefaultsValueModel<String>

    @State private var confirmClearHistory: Bool = false
    @State private var httpAllowlistDraft: String = ""
    @State private var httpAllowlistSyncedValue: String = ""
    @State private var httpAllowlistLoaded: Bool = false

    @State private var webExtensions: JSONValueModel<[BrowserWebExtensionEntry]>
    @State private var discoveredWebExtensions: [SettingsDiscoveredBrowserExtension] = []

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions,
        errorLog: SettingsErrorLog,
        importAnchorID: String? = nil
    ) {
        self.catalog = catalog
        self.hostActions = hostActions
        self.importAnchorID = importAnchorID
        _webExtensions = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.browser.webExtensions,
            errorLog: errorLog
        ))
        _disabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.disabled))
        _engine = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.defaultSearchEngine))
        _customName = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.customSearchEngineName))
        _customURL = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.customSearchEngineURLTemplate))
        _suggestions = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.showSearchSuggestions))
        _theme = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.theme))
        _discardEnabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.discardHiddenWebViews))
        _discardDelay = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.hiddenWebViewDiscardDelaySeconds))
        _askWhereToSaveDownloads = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.askWhereToSaveDownloads))
        _openTermLinks = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.openTerminalLinksInCmuxBrowser))
        _interceptOpen = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.interceptTerminalOpenCommandInCmuxBrowser))
        _hosts = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.hostsToOpenInEmbeddedBrowser))
        _external = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.urlsToAlwaysOpenExternally))
        _httpAllowlist = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.insecureHttpHostsAllowedInEmbeddedBrowser))
        _importHint = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.showImportHintOnBlankTabs))
        _reactGrab = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.reactGrabVersion))
    }

    private static let columnWidth: CGFloat = 196

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.browser", defaultValue: "Browser"), section: .browser)
                .accessibilityIdentifier("SettingsBrowserSection")
            mainCard
            webExtensionsCard
        }
        .confirmationDialog(
            String(localized: "settings.browser.history.clearDialog.title", defaultValue: "Clear browser history?"),
            isPresented: $confirmClearHistory,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.browser.history.clearDialog.confirm", defaultValue: "Clear History"), role: .destructive) {
                hostActions.clearBrowserHistory()
            }
            Button(String(localized: "settings.browser.history.clearDialog.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.browser.history.clearDialog.message", defaultValue: "This removes visited-page suggestions from the browser omnibar."))
        }.task { startSettingsObservation([disabled, engine, customName, customURL, suggestions, theme, discardEnabled, discardDelay, askWhereToSaveDownloads, openTermLinks, interceptOpen, hosts, external, httpAllowlist, importHint, reactGrab]) }
    }

    private var webExtensionsCard: some View {
        BrowserWebExtensionsCard(model: webExtensions, hostActions: hostActions)
    }

    @ViewBuilder
    private var mainCard: some View {
        SettingsCard {
            // Enable cmux Browser
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:browser:enable-browser",
                String(localized: "settings.browser.enabled", defaultValue: "Enable cmux Browser"),
                subtitle: !disabled.current
                    ? String(localized: "settings.browser.enabled.subtitleOn", defaultValue: "Browser tabs, terminal link clicks, and intercepted open commands can use the embedded browser.")
                    : String(localized: "settings.browser.enabled.subtitleOff", defaultValue: "Browser tabs and link interception are disabled. Links open in your default browser.")
            ) {
                Toggle("", isOn: Binding(get: { !disabled.current }, set: { disabled.set(!$0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("BrowserEnabledToggle")
            }
            SettingsCardDivider()

            // Default Search Engine
            SettingsCardRow(
                configurationReview: .json("browser.defaultSearchEngine"),
                String(localized: "settings.browser.searchEngine", defaultValue: "Default Search Engine"),
                subtitle: String(localized: "settings.browser.searchEngine.subtitle", defaultValue: "Used by the browser address bar when input is not a URL."),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { engine.current }, set: { engine.set($0) })) {
                    ForEach(BrowserSearchEngine.allCases, id: \.self) { value in
                        Text(searchEngineLabel(value)).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // Custom Search Engine Name + URL (only when custom)
            if engine.current == .custom {
                SettingsCardRow(
                    configurationReview: .json("browser.customSearchEngineName"),
                    String(localized: "settings.browser.customSearchEngineName", defaultValue: "Custom Search Engine Name"),
                    subtitle: String(localized: "settings.browser.customSearchEngineName.subtitle", defaultValue: "Shown in browser address bar search suggestions."),
                    controlWidth: Self.columnWidth
                ) {
                    TextField("", text: Binding(get: { customName.current }, set: { customName.set($0) }))
                        .textFieldStyle(.roundedBorder)
                }
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .json("browser.customSearchEngineURLTemplate"),
                    String(localized: "settings.browser.customSearchEngineURLTemplate", defaultValue: "Custom Search URL"),
                    subtitle: String(localized: "settings.browser.customSearchEngineURLTemplate.subtitle", defaultValue: "Use {query} or %s for the search terms. Without a placeholder, cmux appends q=."),
                    controlWidth: 330
                ) {
                    TextField("", text: Binding(get: { customURL.current }, set: { customURL.set($0) }))
                        .textFieldStyle(.roundedBorder)
                }
                SettingsCardDivider()
            }

            // Show Search Suggestions
            SettingsCardRow(
                configurationReview: .json("browser.showSearchSuggestions"),
                String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions")
            ) {
                Toggle("", isOn: Binding(get: { suggestions.current }, set: { suggestions.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Browser Theme
            SettingsCardRow(
                configurationReview: .json("browser.theme"),
                String(localized: "settings.browser.theme", defaultValue: "Browser Theme"),
                subtitle: browserThemeSubtitle(theme.current),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { theme.current }, set: { theme.set($0) })) {
                    ForEach(BrowserThemeMode.allCases, id: \.self) { mode in
                        Text(themeDisplayName(mode)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // Browser Memory Saver
            SettingsCardRow(
                configurationReview: .json("browser.discardHiddenWebViews"),
                String(localized: "settings.browser.hiddenWebViewDiscard", defaultValue: "Browser Memory Saver"),
                subtitle: discardEnabled.current
                    ? String(localized: "settings.browser.hiddenWebViewDiscard.subtitleOn", defaultValue: "Hidden browser tabs release page memory after the delay below, then restore when shown again.")
                    : String(localized: "settings.browser.hiddenWebViewDiscard.subtitleOff", defaultValue: "Hidden browser tabs keep page memory until closed.")
            ) {
                Toggle("", isOn: Binding(get: { discardEnabled.current }, set: { discardEnabled.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsBrowserHiddenWebViewDiscardToggle")
            }
            SettingsCardDivider()

            // Memory Saver Delay
            SettingsCardRow(
                configurationReview: .json("browser.hiddenWebViewDiscardDelaySeconds"),
                String(localized: "settings.browser.hiddenWebViewDiscardDelay", defaultValue: "Memory Saver Delay"),
                subtitle: String(localized: "settings.browser.hiddenWebViewDiscardDelay.subtitle", defaultValue: "How long a browser tab must stay hidden before cmux frees its page memory. Active downloads, popups, developer tools, fullscreen, and loading pages are skipped."),
                controlWidth: Self.columnWidth
            ) {
                HStack(spacing: 8) {
                    Text(formatDiscardDelay(discardDelay.current))
                        .cmuxFont(.body, design: .monospaced)
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                    Stepper(
                        "",
                        value: Binding(get: { discardDelay.current }, set: { discardDelay.set($0) }),
                        in: 0...3_600,
                        step: 30
                    )
                    .labelsHidden()
                }
                .disabled(!discardEnabled.current)
                .accessibilityIdentifier("SettingsBrowserHiddenWebViewDiscardDelayStepper")
            }
            SettingsCardDivider()

            // Download Save Prompt
            SettingsCardRow(
                configurationReview: .json("browser.askWhereToSaveDownloads"),
                String(localized: "settings.browser.askWhereToSaveDownloads", defaultValue: "Ask Where to Save Downloads"),
                subtitle: String(localized: "settings.browser.askWhereToSaveDownloads.subtitle", defaultValue: "When off, browser downloads save directly to Downloads without a save panel.")
            ) {
                Toggle("", isOn: Binding(get: { askWhereToSaveDownloads.current }, set: { askWhereToSaveDownloads.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsBrowserAskWhereToSaveDownloadsToggle")
            }
            SettingsCardDivider()

            // Open Terminal Links
            SettingsCardRow(
                configurationReview: .json("browser.openTerminalLinksInCmuxBrowser"),
                String(localized: "settings.browser.openTerminalLinks", defaultValue: "Open Terminal Links in cmux Browser"),
                subtitle: String(localized: "settings.browser.openTerminalLinks.subtitle", defaultValue: "When off, links clicked in terminal output open in your default browser.")
            ) {
                Toggle("", isOn: Binding(get: { openTermLinks.current }, set: { openTermLinks.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Intercept open
            SettingsCardRow(
                configurationReview: .json("browser.interceptTerminalOpenCommandInCmuxBrowser"),
                String(localized: "settings.browser.interceptOpen", defaultValue: "Intercept open http(s) in Terminal"),
                subtitle: String(localized: "settings.browser.interceptOpen.subtitle", defaultValue: "When off, `open https://...` and `open http://...` always use your default browser.")
            ) {
                Toggle("", isOn: Binding(get: { interceptOpen.current }, set: { interceptOpen.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }

            // Hosts + External Patterns (only when relevant)
            if openTermLinks.current || interceptOpen.current {
                SettingsCardDivider()
                hostnameEditor(
                    title: String(localized: "settings.browser.hostWhitelist", defaultValue: "Hosts to Open in Embedded Browser"),
                    subtitle: String(localized: "settings.browser.hostWhitelist.subtitle", defaultValue: "Applies to terminal link clicks and intercepted `open https://...` calls. Only these hosts open in cmux. Others open in your default browser. One host or wildcard per line (for example: example.com, *.internal.example). Leave empty to open all hosts in cmux."),
                    json: "browser.hostsToOpenInEmbeddedBrowser",
                    model: hosts
                )
                SettingsCardDivider()
                hostnameEditor(
                    title: String(localized: "settings.browser.externalPatterns", defaultValue: "URLs to Always Open Externally"),
                    subtitle: String(localized: "settings.browser.externalPatterns.subtitle", defaultValue: "Applies to terminal link clicks and intercepted `open https://...` calls. One rule per line. Plain text matches any URL substring, or prefix with `re:` for regex (for example: openai.com/usage, re:^https?://[^/]*\\.example\\.com/(billing|usage))."),
                    json: "browser.urlsToAlwaysOpenExternally",
                    model: external
                )
            }
            SettingsCardDivider()

            // HTTP Hosts Allowed in Embedded Browser
            httpAllowlistRow(model: httpAllowlist)
                .settingsSearchAnchors(["setting:browser:http-allowlist"])

            SettingsCardDivider()

            // Import Browser Data subsection — tagged with the
            // browserImport anchor id so sidebar deeplinks for that
            // navigation target scroll the user to this inline block.
            importBrowserDataBlock(
                importHintModel: importHint,
                onImport: { hostActions.openBrowserImportFlow() }
            )
            .id(importAnchorID ?? "section:browserImport.inline")
            .settingsSearchHighlight([importAnchorID, "setting:browserImport:import-data"].compactMap { $0 })
            SettingsCardDivider()

            // React Grab Version
            SettingsCardRow(
                configurationReview: .json("browser.reactGrabVersion"),
                String(localized: "settings.browser.reactGrabVersion", defaultValue: "React Grab Version"),
                subtitle: String(localized: "settings.browser.reactGrabVersion.subtitle", defaultValue: "Pinned npm version of react-grab injected by the toolbar button (Cmd+Shift+G). Only versions with a known integrity hash are accepted.")
            ) {
                TextField("", text: Binding(get: { reactGrab.current }, set: { reactGrab.set($0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .cmuxFont(.body, design: .monospaced)
                    .accessibilityIdentifier("SettingsReactGrabVersionField")
            }

            // Browsing History — legacy renders this row unconditionally.
            // When the host has no history store wired in, the count is
            // nil so the subtitle falls back to the generic instruction
            // and the Clear button is disabled.
            let historyCount = hostActions.browserHistoryEntryCount()
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .action,
                searchAnchorID: "setting:browser:history",
                String(localized: "settings.browser.history", defaultValue: "Browsing History"),
                subtitle: historySubtitle(count: historyCount)
            ) {
                Button(String(localized: "settings.browser.history.clearButton", defaultValue: "Clear History…")) {
                    confirmClearHistory = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(historyCount == 0)
            }
        }
    }

    @ViewBuilder
    private func hostnameEditor(title: String, subtitle: String, json: String, model: DefaultsValueModel<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle) {
                EmptyView()
            }
            TextEditor(text: Binding(get: { model.current }, set: { model.set($0) }))
                .cmuxFont(.body, design: .monospaced)
                .frame(minHeight: 60, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func httpAllowlistRow(model: DefaultsValueModel<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "settings.browser.httpAllowlist", defaultValue: "HTTP Hosts Allowed in Embedded Browser"))
                .cmuxFont(size: 13, weight: .semibold)
            Text(String(localized: "settings.browser.httpAllowlist.description", defaultValue: "Controls which HTTP (non-HTTPS) hosts can open in cmux without a warning prompt. Defaults include localhost, *.localhost, 127.0.0.1, ::1, 0.0.0.0, and *.localtest.me."))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $httpAllowlistDraft)
                .cmuxFont(size: 12, weight: .regular, design: .monospaced)
                .frame(minHeight: 86)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .accessibilityIdentifier("SettingsBrowserHTTPAllowlistField")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, *.localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(String(localized: "settings.browser.httpAllowlist.save", defaultValue: "Save")) {
                        model.set(httpAllowlistDraft)
                        httpAllowlistSyncedValue = httpAllowlistDraft
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(httpAllowlistDraft == model.current)
                    .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, *.localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer(minLength: 0)
                        Button(String(localized: "settings.browser.httpAllowlist.save", defaultValue: "Save")) {
                            model.set(httpAllowlistDraft)
                            httpAllowlistSyncedValue = httpAllowlistDraft
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(httpAllowlistDraft == model.current)
                        .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .task {
            if !httpAllowlistLoaded {
                httpAllowlistDraft = model.current
                httpAllowlistSyncedValue = model.current
                httpAllowlistLoaded = true
            }
        }
        .onChange(of: model.current) { _, newValue in
            // Mirrors SettingsDraftState.syncBrowserInsecureHTTPAllowlistFromSavedValue:
            // only refresh the draft when the user hasn't edited it
            // since the last sync. Otherwise keep their in-progress
            // edits intact across external store updates.
            if !httpAllowlistLoaded {
                httpAllowlistDraft = newValue
                httpAllowlistSyncedValue = newValue
                httpAllowlistLoaded = true
                return
            }
            if httpAllowlistDraft == httpAllowlistSyncedValue {
                httpAllowlistDraft = newValue
            }
            httpAllowlistSyncedValue = newValue
        }
    }

    @ViewBuilder
    private func importBrowserDataBlock(importHintModel: DefaultsValueModel<Bool>, onImport: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "settings.browser.import", defaultValue: "Import Browser Data"))
                    .cmuxFont(size: 13, weight: .semibold)
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "browser.import.hint.title", defaultValue: "Import browser data"))
                        .cmuxFont(size: 12.5, weight: .semibold)
                    Text(String(localized: "browser.import.hint.subtitle", defaultValue: "Import bookmarks, history, and cookies from Safari, Chrome, Firefox, Brave, Edge, or Arc. Already-imported entries are deduped automatically."))
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("SettingsBrowserImportSummary")
                    Text(String(localized: "browser.import.hint.settingsFootnote", defaultValue: "You can always find this in Settings > Browser."))
                        .cmuxFont(size: 10.5)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                )
            }
            HStack(spacing: 8) {
                Button(String(localized: "settings.browser.import.choose", defaultValue: "Choose…")) { onImport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsBrowserImportChooseButton")
                Button(String(localized: "settings.browser.import.refresh", defaultValue: "Refresh")) {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
            }
            .accessibilityIdentifier("SettingsBrowserImportActions")
            Toggle(
                String(localized: "settings.browser.import.hint.show", defaultValue: "Show import hint on blank browser tabs"),
                isOn: Binding(get: { importHintModel.current }, set: { importHintModel.set($0) })
            )
            .controlSize(.small)
            .accessibilityIdentifier("SettingsBrowserImportHintToggle")
            .settingsSearchAnchors(["setting:browserImport:import-hint"])
            Text(String(localized: "settings.browser.import.hint.settingsNote", defaultValue: "Shown until you import or dismiss it on a blank tab."))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityIdentifier("SettingsBrowserImportSection")
    }

    private func browserThemeSubtitle(_ mode: BrowserThemeMode) -> String {
        if mode == .system {
            return String(localized: "settings.browser.theme.subtitleSystem", defaultValue: "System follows app and macOS appearance.")
        }
        let name = themeDisplayName(mode)
        return String(localized: "settings.browser.theme.subtitleForced", defaultValue: "\(name) forces that color scheme for compatible pages.")
    }

    private func themeDisplayName(_ mode: BrowserThemeMode) -> String {
        switch mode {
        case .system:
            return String(localized: "theme.system", defaultValue: "System")
        case .light:
            return String(localized: "theme.light", defaultValue: "Light")
        case .dark:
            return String(localized: "theme.dark", defaultValue: "Dark")
        }
    }

    private func searchEngineLabel(_ engine: BrowserSearchEngine) -> String {
        switch engine {
        case .google: return String(localized: "settings.browser.searchEngine.google", defaultValue: "Google")
        case .duckduckgo: return String(localized: "settings.browser.searchEngine.duckduckgo", defaultValue: "DuckDuckGo")
        case .bing: return String(localized: "settings.browser.searchEngine.bing", defaultValue: "Bing")
        case .kagi: return String(localized: "settings.browser.searchEngine.kagi", defaultValue: "Kagi")
        case .startpage: return String(localized: "settings.browser.searchEngine.startpage", defaultValue: "Startpage")
        case .brave: return String(localized: "settings.browser.searchEngine.brave", defaultValue: "Brave Search")
        case .perplexity: return String(localized: "settings.browser.searchEngine.perplexity", defaultValue: "Perplexity")
        case .exa: return String(localized: "settings.browser.searchEngine.exa", defaultValue: "Exa")
        case .yahoo: return String(localized: "settings.browser.searchEngine.yahoo", defaultValue: "Yahoo")
        case .ecosia: return String(localized: "settings.browser.searchEngine.ecosia", defaultValue: "Ecosia")
        case .qwant: return String(localized: "settings.browser.searchEngine.qwant", defaultValue: "Qwant")
        case .mojeek: return String(localized: "settings.browser.searchEngine.mojeek", defaultValue: "Mojeek")
        case .wikipedia: return String(localized: "settings.browser.searchEngine.wikipedia", defaultValue: "Wikipedia")
        case .github: return String(localized: "settings.browser.searchEngine.github", defaultValue: "GitHub")
        case .baidu: return String(localized: "settings.browser.searchEngine.baidu", defaultValue: "Baidu")
        case .yandex: return String(localized: "settings.browser.searchEngine.yandex", defaultValue: "Yandex")
        case .custom: return String(localized: "settings.browser.searchEngine.custom", defaultValue: "Custom")
        }
    }

    /// Builds the Browsing History row subtitle, matching the legacy
    /// `browserHistorySubtitle`: a loading message when the host has
    /// not loaded the history store yet, then dynamic phrasing once
    /// the count is known. Keys mirror legacy
    /// `settings.browser.history.subtitleLoading/Empty/One/Many`.
    private func historySubtitle(count: Int?) -> String {
        switch count {
        case .none:
            return String(localized: "settings.browser.history.subtitleLoading", defaultValue: "Checking browsing history...")
        case .some(0):
            return String(localized: "settings.browser.history.subtitleEmpty", defaultValue: "No saved pages yet.")
        case .some(1):
            return String(localized: "settings.browser.history.subtitleOne", defaultValue: "1 saved page appears in omnibar suggestions.")
        case .some(let n):
            return String(localized: "settings.browser.history.subtitleMany", defaultValue: "\(n) saved pages appear in omnibar suggestions.")
        }
    }

    /// Formats the Memory Saver Delay value as `Xm Ys` (or `Ys`) so
    /// the stepper readout reads naturally for delays measured in
    /// minutes. Matches the legacy
    /// `browserHiddenWebViewDiscardDelayLabel` formatter, including
    /// the localized format strings.
    private func formatDiscardDelay(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 {
            let format = String(localized: "settings.browser.hiddenWebViewDiscardDelay.seconds", defaultValue: "%llds")
            return String.localizedStringWithFormat(format, Int64(total))
        }
        if total % 60 == 0 {
            let format = String(localized: "settings.browser.hiddenWebViewDiscardDelay.minutes", defaultValue: "%lldm")
            return String.localizedStringWithFormat(format, Int64(total / 60))
        }
        let format = String(localized: "settings.browser.hiddenWebViewDiscardDelay.minutesSeconds", defaultValue: "%lldm %llds")
        return String.localizedStringWithFormat(format, Int64(total / 60), Int64(total % 60))
    }
}
