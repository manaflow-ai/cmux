import AppKit
import CmuxBrowser
import CmuxFoundation
import CmuxSettings
import SwiftUI

struct OmnibarPillFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

struct BrowserAddressBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct BrowserAddressBarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Omnibar State Machine

/// Shared omnibar chrome used by browser panels independently of their rendering engine.
struct OmnibarPaneChrome<
    PanelType: OmnibarHostingPanel,
    TrailingAccessories: View,
    LeadingExtras: View
>: View {
    @ObservedObject var panel: PanelType
    let isFocused: Bool
    let chromeStyle: BrowserChromeStyle
    let tabBarFontSize: CGFloat
    let accessorySpacing: CGFloat
    let onRequestPanelFocus: () -> Void
    let onReloadOrStop: () -> Void
    let onReload: () -> Void
    let onHardReload: (() -> Void)?
    let onAddressBarFocusStateChange: (_ focused: Bool) -> Void
    let onChromeHeightChange: (_ height: CGFloat) -> Void
    let onSuggestionsPresentationChange: (BrowserPortalOmnibarSuggestionsConfiguration?) -> Void
    @ViewBuilder let leadingAccessories: () -> LeadingExtras
    @ViewBuilder let trailingAccessories: (_ isCompact: Bool) -> TrailingAccessories

    @AppStorage(BrowserSearchSettingsStore.searchEngineKey)
    var searchEngineRaw = BrowserSearchSettingsStore.defaultSearchEngine.rawValue
    @AppStorage(BrowserSearchSettingsStore.customSearchEngineNameKey)
    var customSearchEngineName = BrowserSearchSettingsStore.defaultCustomSearchEngineName
    @AppStorage(BrowserSearchSettingsStore.customSearchEngineURLTemplateKey)
    var customSearchEngineURLTemplate = BrowserSearchSettingsStore.defaultCustomSearchEngineURLTemplate
    @AppStorage(BrowserSearchSettingsStore.searchSuggestionsEnabledKey)
    var searchSuggestionsEnabledStorage = BrowserSearchSettingsStore.defaultSearchSuggestionsEnabled
    @State var omnibarState = OmnibarState()
    @State var addressBarFocused = false
    @State var omnibarSuggestionRefreshScheduler = OmnibarSuggestionRefreshScheduler()
    @State var omnibarSuggestionRefreshConsumerTask: Task<Void, Never>?
    @State var suggestionTask: Task<Void, Never>?
    @State var isLoadingRemoteSuggestions = false
    @State var latestRemoteSuggestionQuery = ""
    @State var latestRemoteSuggestions: [String] = []
    @State var inlineCompletion: OmnibarInlineCompletion?
    @State var omnibarSelectionRange = NSRange(location: NSNotFound, length: 0)
    @State var omnibarHasMarkedText = false
    @State var suppressNextFocusLostRevert = false
    @State var omnibarPillFrame: CGRect = .zero
    @State var addressBarHeight: CGFloat = 0
    @State var addressBarWidth: CGFloat = 0
    @State var lastHandledAddressBarFocusRequestId: UUID?
    @State var omnibarSelectAllRequestId: UInt64 = 0
    @State var pendingFocusGainedSelectionIntent: BrowserAddressBarFocusSelectionIntent =
        .preserveFieldEditorSelection

    static var compactChromeWidthThreshold: CGFloat { 420 }
    var isChromeCompact: Bool {
        addressBarWidth > 0 && addressBarWidth < Self.compactChromeWidthThreshold
    }
    let omnibarPillCornerRadius: CGFloat = 10
    let addressBarVerticalPadding: CGFloat = 4
    var chromeMetrics: BrowserChromeMetrics {
        BrowserChromeMetrics(tabBarFontSize: tabBarFontSize)
    }
    var addressBarButtonHitSize: CGFloat { chromeMetrics.buttonHitSize }

    var searchConfiguration: BrowserSearchConfiguration {
        BrowserSearchSettingsStore().configuration(
            engineRaw: searchEngineRaw,
            customName: customSearchEngineName,
            customURLTemplate: customSearchEngineURLTemplate
        )
    }

    var searchSuggestionsEnabled: Bool {
        _ = searchSuggestionsEnabledStorage
        return BrowserSearchSettingsStore(defaults: .standard).currentSearchSuggestionsEnabled
    }

    var remoteSuggestionsEnabled: Bool {
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON"] != nil ||
            UserDefaults.standard.string(forKey: "CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON") != nil {
            return true
        }
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] == "1" {
            return false
        }
        return searchSuggestionsEnabled
    }

    var hasActionableOmnibarSuggestions: Bool {
        !omnibarHasMarkedText && !omnibarState.suggestions.isEmpty
    }

    var historyStoreIdentity: ObjectIdentifier {
        ObjectIdentifier(panel.historyStore)
    }

    var hasVisibleOmnibarSuggestions: Bool {
        panel.isOmnibarVisible &&
            addressBarFocused &&
            hasActionableOmnibarSuggestions &&
            omnibarPillFrame.width > 0
    }

    var shouldRenderOmnibarSuggestionsInPortal: Bool {
        hasVisibleOmnibarSuggestions
    }

    var suggestionsPresentation: BrowserPortalOmnibarSuggestionsConfiguration? {
        guard hasVisibleOmnibarSuggestions else { return nil }
        let top = max(0, omnibarPillFrame.maxY + 3 - addressBarHeight)
        let height = OmnibarSuggestionsView.popupHeight(for: omnibarState.suggestions)
        guard height > 0 else { return nil }
        return BrowserPortalOmnibarSuggestionsConfiguration(
            panelId: panel.id,
            popupFrame: CGRect(
                x: omnibarPillFrame.minX,
                y: top,
                width: omnibarPillFrame.width,
                height: height
            ),
            colorScheme: chromeStyle.colorScheme,
            engineName: searchConfiguration.displayName,
            items: omnibarState.suggestions,
            selectedIndex: omnibarState.selectedSuggestionIndex,
            isLoadingRemoteSuggestions: isLoadingRemoteSuggestions,
            searchSuggestionsEnabled: remoteSuggestionsEnabled,
            onCommit: commitSuggestion,
            onHighlight: { idx in
                let effects = omnibarReduce(state: &omnibarState, event: .highlightIndex(idx))
                applyOmnibarEffects(effects)
                publishSuggestionsPresentation()
            }
        )
    }

    var body: some View {
        Group {
            if panel.isOmnibarVisible {
                addressBar
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .coordinateSpace(name: "BrowserPanelViewSpace")
        .onPreferenceChange(OmnibarPillFramePreferenceKey.self) { frame in
            omnibarPillFrame = frame
            publishSuggestionsPresentation()
        }
        .onPreferenceChange(BrowserAddressBarHeightPreferenceKey.self) { height in
            addressBarHeight = height
            onChromeHeightChange(height)
            publishSuggestionsPresentation()
        }
        .onPreferenceChange(BrowserAddressBarWidthPreferenceKey.self) { width in
            addressBarWidth = width
        }
        .onAppear {
            startOmnibarSuggestionRefreshConsumer()
            panel.historyStore.loadIfNeeded()
            syncURLFromPanel()
            applyPendingAddressBarFocusRequestIfNeeded()
            autoFocusOmnibarIfBlank()
            publishSuggestionsPresentation()
        }
        .onDisappear {
            stopOmnibarSuggestionRefreshConsumer()
            cancelPendingOmnibarSuggestionWork()
            onSuggestionsPresentationChange(nil)
        }
        .onChange(of: panel.omnibarDisplayURL) { _, _ in
            handleCurrentURLChange()
        }
        .onChange(of: historyStoreIdentity) { _, _ in
            panel.historyStore.loadIfNeeded()
            if addressBarFocused {
                refreshSuggestions()
            }
        }
        .onChange(of: panel.pendingAddressBarFocusRequestId) { _, _ in
            applyPendingAddressBarFocusRequestIfNeeded()
        }
        .onChange(of: panel.isOmnibarVisible) { _, isVisible in
            if !isVisible {
                hideSuggestions()
                setAddressBarFocused(false, reason: "omnibarVisibility.hidden")
                addressBarHeight = 0
            } else {
                applyPendingAddressBarFocusRequestIfNeeded()
            }
            publishSuggestionsPresentation()
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                applyPendingAddressBarFocusRequestIfNeeded()
                autoFocusOmnibarIfBlank()
            } else {
                hideSuggestions()
                setAddressBarFocused(false, reason: "panelFocus.onChange.unfocused")
            }
        }
        .onChange(of: addressBarFocused) { _, focused in
            handleAddressBarFocusedChange(focused)
            publishSuggestionsPresentation()
        }
        .onChange(of: omnibarState) { _, _ in
            publishSuggestionsPresentation()
        }
        .onChange(of: isLoadingRemoteSuggestions) { _, _ in
            publishSuggestionsPresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .commandPaletteVisibilityDidChange)) {
            notification in
            guard commandPaletteVisibilityNotificationMatchesPanelWindow(notification) else { return }
            applyPendingAddressBarFocusRequestIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserMoveOmnibarSelection)) {
            notification in
            handleMoveOmnibarSelection(notification)
        }
        .onReceive(panel.historyStore.$entries) { _ in
            handleHistoryEntriesChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserDidBlurAddressBar)) {
            notification in
            handleExternalAddressBarBlur(notification)
        }
    }

    var addressBar: some View {
        HStack(spacing: 8) {
            addressBarButtonBar

            omnibarField
                .accessibilityIdentifier("BrowserOmnibarPill")
                .accessibilityLabel(
                    String(localized: "browser.omnibar.accessibilityLabel", defaultValue: "Browser omnibar")
                )

            HStack(spacing: accessorySpacing) {
                trailingAccessories(isChromeCompact)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, addressBarVerticalPadding)
        .background(Color(nsColor: chromeStyle.backgroundColor))
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: BrowserAddressBarWidthPreferenceKey.self,
                    value: geo.size.width
                )
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: BrowserAddressBarHeightPreferenceKey.self,
                    value: geo.size.height
                )
            }
        }
        .zIndex(1)
        .environment(\.colorScheme, chromeStyle.colorScheme)
    }

    var addressBarButtonBar: some View {
        HStack(spacing: 0) {
            Button {
#if DEBUG
                cmuxDebugLog("browser.back panel=\(panel.id.uuidString.prefix(5))")
#endif
                panel.goBack()
            } label: {
                CmuxSystemSymbolImage(
                    systemName: "chevron.left",
                    pointSize: chromeMetrics.navigationIconFontSize,
                    weight: .medium
                )
                .frame(
                    width: addressBarButtonHitSize,
                    height: addressBarButtonHitSize,
                    alignment: .center
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .disabled(!panel.canGoBack)
            .opacity(panel.canGoBack ? 1.0 : 0.4)
            .safeHelp(String(localized: "browser.goBack", defaultValue: "Go Back"))

            Button {
#if DEBUG
                cmuxDebugLog("browser.forward panel=\(panel.id.uuidString.prefix(5))")
#endif
                panel.goForward()
            } label: {
                CmuxSystemSymbolImage(
                    systemName: "chevron.right",
                    pointSize: chromeMetrics.navigationIconFontSize,
                    weight: .medium
                )
                .frame(
                    width: addressBarButtonHitSize,
                    height: addressBarButtonHitSize,
                    alignment: .center
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .disabled(!panel.canGoForward)
            .opacity(panel.canGoForward ? 1.0 : 0.4)
            .safeHelp(String(localized: "browser.goForward", defaultValue: "Go Forward"))

            Button(action: onReloadOrStop) {
                CmuxSystemSymbolImage(
                    systemName: panel.isLoading ? "xmark" : "arrow.clockwise",
                    pointSize: chromeMetrics.navigationIconFontSize,
                    weight: .medium
                )
                .frame(
                    width: addressBarButtonHitSize,
                    height: addressBarButtonHitSize,
                    alignment: .center
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .contextMenu {
                Button(String(localized: "browser.reload", defaultValue: "Reload"), action: onReload)
                if let onHardReload {
                    Button(
                        String(localized: "menu.view.hardRefresh", defaultValue: "Hard Refresh"),
                        action: onHardReload
                    )
                }
            }
            .safeHelp(
                panel.isLoading
                    ? String(localized: "browser.stop", defaultValue: "Stop")
                    : String(localized: "browser.reload", defaultValue: "Reload")
            )

            leadingAccessories()
        }
    }

    var omnibarField: some View {
        let showSecureBadge = panel.omnibarDisplayURL?.scheme == "https"

        return HStack(spacing: 4) {
            if showSecureBadge {
                CmuxSystemSymbolImage(
                    systemName: "lock.fill",
                    pointSize: chromeMetrics.secureBadgeFontSize
                )
                .foregroundColor(.secondary)
            }

            OmnibarTextFieldRepresentable(
                panelId: panel.id,
                fontSize: chromeMetrics.omnibarFontSize,
                text: Binding(
                    get: { omnibarState.buffer },
                    set: { newValue in
                        let effects = omnibarReduce(
                            state: &omnibarState,
                            event: .bufferChanged(newValue)
                        )
                        applyOmnibarEffects(effects)
                        if !effects.shouldClearInlineCompletion {
                            refreshInlineCompletion()
                        }
                    }
                ),
                isFocused: $addressBarFocused,
                selectAllRequestId: omnibarSelectAllRequestId,
                inlineCompletion: inlineCompletion,
                placeholder: String(
                    localized: "browser.addressBar.placeholder",
                    defaultValue: "Search or enter URL"
                ),
                onTap: handleOmnibarTap,
                onSubmit: handleOmnibarSubmit,
                onEscape: handleOmnibarEscape,
                onFieldLostFocus: {
                    setAddressBarFocused(false, reason: "omnibar.fieldLostFocus")
                },
                onMoveSelection: { delta in
                    guard canHandleOmnibarSuggestionInteraction() else { return }
                    let effects = omnibarReduce(
                        state: &omnibarState,
                        event: .moveSelection(delta: delta)
                    )
                    applyOmnibarEffects(effects)
                    refreshInlineCompletion()
                },
                onDeleteSelectedSuggestion: deleteSelectedSuggestionIfPossible,
                onAcceptInlineCompletion: acceptInlineCompletion,
                onDeleteBackwardWithInlineSelection: handleInlineBackspace,
                onClearTypedPrefixWithInlineSelection: handleInlineClearTypedPrefix,
                onDeleteWordBackwardWithInlineSelection: handleInlineDeleteWordBackward,
                onSelectionChanged: handleOmnibarSelectionChange,
                shouldSuppressWebViewFocus: {
                    panel.shouldSuppressContentFocus()
                }
            )
            .frame(height: chromeMetrics.omnibarFieldHeight)
            .accessibilityIdentifier("BrowserOmnibarTextField")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: omnibarPillCornerRadius, style: .continuous)
                .fill(Color(nsColor: chromeStyle.omnibarPillBackgroundColor))
        )
        .overlay {
            BrowserOmnibarInteractionRepresentable(panelId: panel.id)
        }
        .overlay(
            RoundedRectangle(cornerRadius: omnibarPillCornerRadius, style: .continuous)
                .stroke(addressBarFocused ? cmuxAccentColor() : Color.clear, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: OmnibarPillFramePreferenceKey.self,
                    value: geo.frame(in: .named("BrowserPanelViewSpace"))
                )
            }
        }
    }

}
