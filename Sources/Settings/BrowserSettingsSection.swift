import AppKit
import SwiftUI

struct BrowserSettingsSection: View {
    let pickerColumnWidth: CGFloat

    @Binding var browserSearchEngine: String
    @Binding var browserCustomSearchEngineName: String
    @Binding var browserCustomSearchEngineURLTemplate: String
    @Binding var browserSearchSuggestionsEnabled: Bool
    @Binding var browserThemeMode: String
    @Binding var browserDisabled: Bool
    @Binding var browserHiddenWebViewDiscardEnabled: Bool
    @Binding var browserHiddenWebViewDiscardDelay: Double
    @Binding var openTerminalLinksInCmuxBrowser: Bool
    @Binding var interceptTerminalOpenCommandInCmuxBrowser: Bool
    @Binding var browserHostWhitelist: String
    @Binding var browserExternalOpenPatterns: String
    @Binding var browserInsecureHTTPAllowlistDraft: String
    let browserInsecureHTTPAllowlistSavedValue: String
    let saveBrowserInsecureHTTPAllowlist: () -> Void
    @Binding var showBrowserImportHintOnBlankTabs: Bool
    @Binding var isBrowserImportHintDismissed: Bool
    let browserImportSubtitle: String
    let browserImportHintSettingsNote: String
    let refreshDetectedImportBrowsers: () -> Void
    let isDetectingImportBrowsers: Bool
    @Binding var reactGrabVersion: String
    let browserHistorySubtitle: String
    @Binding var showClearBrowserHistoryConfirmation: Bool
    let didLoadBrowserHistoryForSettings: Bool
    let browserHistoryEntryCount: Int

    private var selectedBrowserThemeMode: BrowserThemeMode {
        BrowserThemeSettings.mode(for: browserThemeMode)
    }

    private var browserThemeModeSelection: Binding<String> {
        Binding(
            get: { browserThemeMode },
            set: { newValue in
                browserThemeMode = BrowserThemeSettings.mode(for: newValue).rawValue
            }
        )
    }

    private var browserEnabledBinding: Binding<Bool> {
        Binding(
            get: { !browserDisabled },
            set: { newValue in
                BrowserAvailabilitySettings.setDisabled(!newValue)
                browserDisabled = !newValue
            }
        )
    }

    private var browserEnabledSubtitle: String {
        if browserDisabled {
            return String(localized: "settings.browser.enabled.subtitleOff", defaultValue: "Browser tabs and link interception are disabled. Links open in your default browser.")
        }
        return String(localized: "settings.browser.enabled.subtitleOn", defaultValue: "Browser tabs, terminal link clicks, and intercepted open commands can use the embedded browser.")
    }

    private var browserHiddenWebViewDiscardDelayBinding: Binding<Double> {
        Binding(
            get: { BrowserHiddenWebViewDiscardPolicy.clampedHiddenDelay(browserHiddenWebViewDiscardDelay) },
            set: { browserHiddenWebViewDiscardDelay = BrowserHiddenWebViewDiscardPolicy.clampedHiddenDelay($0) }
        )
    }

    private var browserHiddenWebViewDiscardSubtitle: String {
        if browserHiddenWebViewDiscardEnabled {
            return String(localized: "settings.browser.hiddenWebViewDiscard.subtitleOn", defaultValue: "Hidden browser tabs release page memory after the delay below, then restore when shown again.")
        }
        return String(localized: "settings.browser.hiddenWebViewDiscard.subtitleOff", defaultValue: "Hidden browser tabs keep page memory until closed.")
    }

    private var browserHiddenWebViewDiscardDelaySubtitle: String {
        String(localized: "settings.browser.hiddenWebViewDiscardDelay.subtitle", defaultValue: "How long a browser tab must stay hidden before cmux frees its page memory. Active downloads, popups, developer tools, fullscreen, and loading pages are skipped.")
    }

    private var browserHiddenWebViewDiscardDelayLabel: String {
        let seconds = Int(BrowserHiddenWebViewDiscardPolicy.clampedHiddenDelay(browserHiddenWebViewDiscardDelay).rounded())
        if seconds < 60 {
            let format = String(localized: "settings.browser.hiddenWebViewDiscardDelay.seconds", defaultValue: "%llds")
            return String.localizedStringWithFormat(format, Int64(seconds))
        }
        if seconds % 60 == 0 {
            let format = String(localized: "settings.browser.hiddenWebViewDiscardDelay.minutes", defaultValue: "%lldm")
            return String.localizedStringWithFormat(format, Int64(seconds / 60))
        }
        let format = String(localized: "settings.browser.hiddenWebViewDiscardDelay.minutesSeconds", defaultValue: "%lldm %llds")
        return String.localizedStringWithFormat(format, Int64(seconds / 60), Int64(seconds % 60))
    }

    private var browserImportHintVisibilityBinding: Binding<Bool> {
        Binding(
            get: { showBrowserImportHintOnBlankTabs },
            set: { newValue in
                showBrowserImportHintOnBlankTabs = newValue
                if newValue {
                    isBrowserImportHintDismissed = false
                }
            }
        )
    }

    private var browserInsecureHTTPAllowlistHasUnsavedChanges: Bool {
        browserInsecureHTTPAllowlistDraft != browserInsecureHTTPAllowlistSavedValue
    }

    var body: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.browser", defaultValue: "Browser"))
            .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .browser))
            .accessibilityIdentifier("SettingsBrowserSection")
        SettingsCard {
            browserEnabledSettingsRows

            SettingsPickerRow(
                configurationReview: .json("browser.defaultSearchEngine"),
                String(localized: "settings.browser.searchEngine", defaultValue: "Default Search Engine"),
                subtitle: String(localized: "settings.browser.searchEngine.subtitle", defaultValue: "Used by the browser address bar when input is not a URL."),
                controlWidth: pickerColumnWidth,
                selection: $browserSearchEngine
            ) {
                ForEach(BrowserSearchEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }

            SettingsCardDivider()

            if browserSearchEngine == BrowserSearchEngine.custom.rawValue {
                SettingsCardRow(
                    configurationReview: .json("browser.customSearchEngineName"),
                    String(localized: "settings.browser.customSearchEngineName", defaultValue: "Custom Search Engine Name"),
                    subtitle: String(localized: "settings.browser.customSearchEngineName.subtitle", defaultValue: "Shown in browser address bar search suggestions."),
                    controlWidth: pickerColumnWidth
                ) {
                    TextField("", text: $browserCustomSearchEngineName)
                        .textFieldStyle(.roundedBorder)
                }

                SettingsCardDivider()

                SettingsCardRow(
                    configurationReview: .json("browser.customSearchEngineURLTemplate"),
                    String(localized: "settings.browser.customSearchEngineURLTemplate", defaultValue: "Custom Search URL"),
                    subtitle: String(localized: "settings.browser.customSearchEngineURLTemplate.subtitle", defaultValue: "Use {query} or %s for the search terms. Without a placeholder, cmux appends q=."),
                    controlWidth: 330
                ) {
                    TextField("", text: $browserCustomSearchEngineURLTemplate)
                        .textFieldStyle(.roundedBorder)
                }

                SettingsCardDivider()
            }

            SettingsCardRow(configurationReview: .json("browser.showSearchSuggestions"), String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions")) {
                Toggle("", isOn: $browserSearchSuggestionsEnabled)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsPickerRow(
                configurationReview: .json("browser.theme"),
                String(localized: "settings.browser.theme", defaultValue: "Browser Theme"),
                subtitle: selectedBrowserThemeMode == .system
                    ? String(localized: "settings.browser.theme.subtitleSystem", defaultValue: "System follows app and macOS appearance.")
                    : String(localized: "settings.browser.theme.subtitleForced", defaultValue: "\(selectedBrowserThemeMode.displayName) forces that color scheme for compatible pages."),
                controlWidth: pickerColumnWidth,
                selection: browserThemeModeSelection
            ) {
                ForEach(BrowserThemeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("browser.discardHiddenWebViews"),
                String(localized: "settings.browser.hiddenWebViewDiscard", defaultValue: "Browser Memory Saver"),
                subtitle: browserHiddenWebViewDiscardSubtitle,
                searchAnchorID: SettingsSearchIndex.settingID(for: .browser, idSuffix: "hidden-webview-discard")
            ) {
                Toggle("", isOn: $browserHiddenWebViewDiscardEnabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsBrowserHiddenWebViewDiscardToggle")
                    .accessibilityLabel(String(localized: "settings.browser.hiddenWebViewDiscard", defaultValue: "Browser Memory Saver"))
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("browser.hiddenWebViewDiscardDelaySeconds"),
                String(localized: "settings.browser.hiddenWebViewDiscardDelay", defaultValue: "Memory Saver Delay"),
                subtitle: browserHiddenWebViewDiscardDelaySubtitle,
                controlWidth: pickerColumnWidth,
                searchAnchorID: SettingsSearchIndex.settingID(for: .browser, idSuffix: "hidden-webview-discard-delay")
            ) {
                HStack(spacing: 8) {
                    Text(browserHiddenWebViewDiscardDelayLabel)
                        .font(.system(.body, design: .monospaced))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)

                    Stepper(
                        "",
                        value: browserHiddenWebViewDiscardDelayBinding,
                        in: BrowserHiddenWebViewDiscardPolicy.minimumHiddenDelay...BrowserHiddenWebViewDiscardPolicy.maximumHiddenDelay,
                        step: 30
                    )
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "settings.browser.hiddenWebViewDiscardDelay", defaultValue: "Memory Saver Delay"))
                    .accessibilityValue(browserHiddenWebViewDiscardDelayLabel)
                }
                .disabled(!browserHiddenWebViewDiscardEnabled)
                .accessibilityIdentifier("SettingsBrowserHiddenWebViewDiscardDelayStepper")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("browser.openTerminalLinksInCmuxBrowser"),
                String(localized: "settings.browser.openTerminalLinks", defaultValue: "Open Terminal Links in cmux Browser"),
                subtitle: String(localized: "settings.browser.openTerminalLinks.subtitle", defaultValue: "When off, links clicked in terminal output open in your default browser.")
            ) {
                Toggle("", isOn: $openTerminalLinksInCmuxBrowser)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("browser.interceptTerminalOpenCommandInCmuxBrowser"),
                String(localized: "settings.browser.interceptOpen", defaultValue: "Intercept open http(s) in Terminal"),
                subtitle: String(localized: "settings.browser.interceptOpen.subtitle", defaultValue: "When off, `open https://...` and `open http://...` always use your default browser.")
            ) {
                Toggle("", isOn: $interceptTerminalOpenCommandInCmuxBrowser)
                    .labelsHidden()
                    .controlSize(.small)
            }

            if openTerminalLinksInCmuxBrowser || interceptTerminalOpenCommandInCmuxBrowser {
                SettingsCardDivider()
                browserHostWhitelistRows
                SettingsCardDivider()
                browserExternalOpenPatternsRows
            }

            SettingsCardDivider()

            browserHTTPAllowlistRows

            SettingsCardDivider()

            BrowserExtensionsSettingsRows()

            SettingsCardDivider()

            browserImportRows

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("browser.reactGrabVersion"),
                String(localized: "settings.browser.reactGrabVersion", defaultValue: "React Grab Version"),
                subtitle: String(localized: "settings.browser.reactGrabVersion.subtitle", defaultValue: "Pinned npm version of react-grab injected by the toolbar button (Cmd+Shift+G). Only versions with a known integrity hash are accepted.")
            ) {
                TextField("", text: $reactGrabVersion)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("SettingsReactGrabVersionField")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .action,
                String(localized: "settings.browser.history", defaultValue: "Browsing History"),
                subtitle: browserHistorySubtitle,
                searchAnchorID: SettingsSearchIndex.settingID(for: .browser, idSuffix: "history")
            ) {
                Button(String(localized: "settings.browser.history.clearButton", defaultValue: "Clear History…")) {
                    showClearBrowserHistoryConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!didLoadBrowserHistoryForSettings || browserHistoryEntryCount == 0)
            }
            .settingsLazyLoadTrigger(.browserHistory)
        }
    }

    @ViewBuilder
    private var browserEnabledSettingsRows: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.browser.enabled", defaultValue: "Enable cmux Browser"),
            subtitle: browserEnabledSubtitle,
            searchAnchorID: SettingsSearchIndex.settingID(for: .browser, idSuffix: "enable-browser")
        ) {
            Toggle("", isOn: browserEnabledBinding)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("BrowserEnabledToggle")
        }

        SettingsCardDivider()
    }

    private var browserHostWhitelistRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCardRow(
                configurationReview: .json("browser.hostsToOpenInEmbeddedBrowser"),
                String(localized: "settings.browser.hostWhitelist", defaultValue: "Hosts to Open in Embedded Browser"),
                subtitle: String(localized: "settings.browser.hostWhitelist.subtitle", defaultValue: "Applies to terminal link clicks and intercepted `open https://...` calls. Only these hosts open in cmux. Others open in your default browser. One host or wildcard per line (for example: example.com, *.internal.example). Leave empty to open all hosts in cmux.")
            ) {
                EmptyView()
            }

            TextEditor(text: $browserHostWhitelist)
                .font(.system(.body, design: .monospaced))
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

    private var browserExternalOpenPatternsRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCardRow(
                configurationReview: .json("browser.urlsToAlwaysOpenExternally"),
                String(localized: "settings.browser.externalPatterns", defaultValue: "URLs to Always Open Externally"),
                subtitle: String(localized: "settings.browser.externalPatterns.subtitle", defaultValue: "Applies to terminal link clicks and intercepted `open https://...` calls. One rule per line. Plain text matches any URL substring, or prefix with `re:` for regex (for example: openai.com/usage, re:^https?://[^/]*\\.example\\.com/(billing|usage)).")
            ) {
                EmptyView()
            }

            TextEditor(text: $browserExternalOpenPatterns)
                .font(.system(.body, design: .monospaced))
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

    private var browserHTTPAllowlistRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "settings.browser.httpAllowlist", defaultValue: "HTTP Hosts Allowed in Embedded Browser"))
                .font(.system(size: 13, weight: .semibold))

            Text(String(localized: "settings.browser.httpAllowlist.description", defaultValue: "Controls which HTTP (non-HTTPS) hosts can open in cmux without a warning prompt. Defaults include localhost, *.localhost, 127.0.0.1, ::1, 0.0.0.0, and *.localtest.me."))
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $browserInsecureHTTPAllowlistDraft)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
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

            browserHTTPAllowlistControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .settingsSearchAnchor(SettingsSearchIndex.settingID(for: .browser, idSuffix: "http-allowlist"))
    }

    @ViewBuilder
    private var browserHTTPAllowlistControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                browserHTTPAllowlistHint

                Spacer(minLength: 0)

                browserHTTPAllowlistSaveButton
            }

            VStack(alignment: .leading, spacing: 8) {
                browserHTTPAllowlistHint

                HStack {
                    Spacer(minLength: 0)
                    browserHTTPAllowlistSaveButton
                }
            }
        }
    }

    private var browserHTTPAllowlistHint: some View {
        Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, *.localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var browserHTTPAllowlistSaveButton: some View {
        Button(String(localized: "settings.browser.httpAllowlist.save", defaultValue: "Save")) {
            saveBrowserInsecureHTTPAllowlist()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!browserInsecureHTTPAllowlistHasUnsavedChanges)
        .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
    }

    private var browserImportRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            browserImportSummaryRows

            HStack(spacing: 8) {
                Button(String(localized: "settings.browser.import.choose", defaultValue: "Choose…")) {
                    BrowserDataImportCoordinator.shared.presentImportDialog()
                    refreshDetectedImportBrowsers()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBrowserImportChooseButton")

                Button(String(localized: "settings.browser.import.refresh", defaultValue: "Refresh")) {
                    refreshDetectedImportBrowsers()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDetectingImportBrowsers)
            }
            .accessibilityIdentifier("SettingsBrowserImportActions")

            Toggle(
                String(localized: "settings.browser.import.hint.show", defaultValue: "Show import hint on blank browser tabs"),
                isOn: browserImportHintVisibilityBinding
            )
            .controlSize(.small)
            .accessibilityIdentifier("SettingsBrowserImportHintToggle")
            .settingsSearchAnchor(SettingsSearchIndex.settingID(for: .browserImport, idSuffix: "import-hint"))

            Text(browserImportHintSettingsNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsSearchAnchors([
            SettingsSearchIndex.sectionID(for: .browserImport),
            SettingsSearchIndex.settingID(for: .browserImport, idSuffix: "import-data")
        ])
        .accessibilityIdentifier("SettingsBrowserImportSection")
        .settingsLazyLoadTrigger(.browserImport)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var browserImportSummaryRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "settings.browser.import", defaultValue: "Import Browser Data"))
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "browser.import.hint.title", defaultValue: "Import browser data"))
                    .font(.system(size: 12.5, weight: .semibold))

                Text(browserImportSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SettingsBrowserImportSummary")

                Text(String(localized: "browser.import.hint.settingsFootnote", defaultValue: "You can always find this in Settings > Browser."))
                    .font(.system(size: 10.5))
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
    }
}
