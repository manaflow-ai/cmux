import Bonsplit
import SwiftUI
import WebKit
import AppKit

struct OmnibarInlineCompletion: Equatable {
    let typedText: String
    let displayText: String
    let acceptedText: String

    var suffixRange: NSRange {
        let typedCount = typedText.utf16.count
        let fullCount = displayText.utf16.count
        return NSRange(location: typedCount, length: max(0, fullCount - typedCount))
    }
}

/// View for rendering a browser panel with address bar
struct BrowserPanelView: View {
    @ObservedObject var panel: BrowserPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void
    @State private var omnibarState = OmnibarState()
    @State private var addressBarFocused: Bool = false
    @AppStorage(BrowserSearchSettings.searchEngineKey) private var searchEngineRaw = BrowserSearchSettings.defaultSearchEngine.rawValue
    @AppStorage(BrowserSearchSettings.searchSuggestionsEnabledKey) private var searchSuggestionsEnabledStorage = BrowserSearchSettings.defaultSearchSuggestionsEnabled
    @State private var suggestionTask: Task<Void, Never>?
    @State private var isLoadingRemoteSuggestions: Bool = false
    @State private var latestRemoteSuggestionQuery: String = ""
    @State private var latestRemoteSuggestions: [String] = []
    @State private var inlineCompletion: OmnibarInlineCompletion?
    @State private var omnibarSelectionRange: NSRange = NSRange(location: NSNotFound, length: 0)
    @State private var omnibarHasMarkedText: Bool = false
    @State private var suppressNextFocusLostRevert: Bool = false
    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashFadeWorkItem: DispatchWorkItem?
    @State private var omnibarPillFrame: CGRect = .zero
    private let omnibarPillCornerRadius: CGFloat = 12

    private var searchEngine: BrowserSearchEngine {
        BrowserSearchEngine(rawValue: searchEngineRaw) ?? BrowserSearchSettings.defaultSearchEngine
    }

    private var searchSuggestionsEnabled: Bool {
        // Touch @AppStorage so SwiftUI invalidates this view when settings change.
        _ = searchSuggestionsEnabledStorage
        return BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: .standard)
    }

    private var remoteSuggestionsEnabled: Bool {
        // Deterministic UI-test hook: force remote path on even if a persisted
        // setting disabled suggestions in previous sessions.
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON"] != nil ||
            UserDefaults.standard.string(forKey: "CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON") != nil {
            return true
        }
        // Keep UI tests deterministic by disabling network suggestions when requested.
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] == "1" {
            return false
        }
        return searchSuggestionsEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            webView
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: Color.accentColor.opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(6)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if addressBarFocused, !omnibarState.suggestions.isEmpty, omnibarPillFrame.width > 0 {
                OmnibarSuggestionsView(
                    engineName: searchEngine.displayName,
                    items: omnibarState.suggestions,
                    selectedIndex: omnibarState.selectedSuggestionIndex,
                    isLoadingRemoteSuggestions: isLoadingRemoteSuggestions,
                    searchSuggestionsEnabled: remoteSuggestionsEnabled,
                    onCommit: { item in
                        commitSuggestion(item)
                    },
                    onHighlight: { idx in
                        let effects = omnibarReduce(state: &omnibarState, event: .highlightIndex(idx))
                        applyOmnibarEffects(effects)
                    }
                )
                .frame(width: omnibarPillFrame.width)
                .offset(x: omnibarPillFrame.minX, y: omnibarPillFrame.maxY + 6)
                .zIndex(1000)
            }
        }
        .coordinateSpace(name: "BrowserPanelViewSpace")
        .onPreferenceChange(OmnibarPillFramePreferenceKey.self) { frame in
            omnibarPillFrame = frame
        }
        .onAppear {
            UserDefaults.standard.register(defaults: [
                BrowserSearchSettings.searchEngineKey: BrowserSearchSettings.defaultSearchEngine.rawValue,
                BrowserSearchSettings.searchSuggestionsEnabledKey: BrowserSearchSettings.defaultSearchSuggestionsEnabled,
            ])
            syncURLFromPanel()
            // If the browser surface is focused but has no URL loaded yet, auto-focus the omnibar.
            autoFocusOmnibarIfBlank()
            BrowserHistoryStore.shared.loadIfNeeded()
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
        .onChange(of: panel.currentURL) { _ in
            let addressWasEmpty = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            syncURLFromPanel()
            // If we auto-focused a blank omnibar but then a URL loads programmatically, move focus
            // into WebKit unless the user had already started typing.
            if addressBarFocused,
               !panel.shouldSuppressWebViewFocus(),
               addressWasEmpty,
               !isWebViewBlank() {
                addressBarFocused = false
            }
        }
        .onChange(of: isFocused) { focused in
            // Ensure this view doesn't retain focus while hidden (bonsplit keepAllAlive).
            if focused {
                autoFocusOmnibarIfBlank()
            } else {
                hideSuggestions()
                addressBarFocused = false
            }
        }
        .onChange(of: addressBarFocused) { focused in
            let urlString = panel.preferredURLStringForOmnibar() ?? ""
            if focused {
                panel.beginSuppressWebViewFocusForAddressBar()
                NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: panel.id)
                // Only request panel focus if this pane isn't currently focused. When already
                // focused (e.g. Cmd+L), forcing focus can steal first responder back to WebKit.
                if !isFocused {
                    onRequestPanelFocus()
                }
                let effects = omnibarReduce(state: &omnibarState, event: .focusGained(currentURLString: urlString))
                applyOmnibarEffects(effects)
                refreshInlineCompletion()
            } else {
                panel.endSuppressWebViewFocusForAddressBar()
                NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panel.id)
                if suppressNextFocusLostRevert {
                    suppressNextFocusLostRevert = false
                    let effects = omnibarReduce(state: &omnibarState, event: .focusLostPreserveBuffer(currentURLString: urlString))
                    applyOmnibarEffects(effects)
                } else {
                    let effects = omnibarReduce(state: &omnibarState, event: .focusLostRevertBuffer(currentURLString: urlString))
                    applyOmnibarEffects(effects)
                }
                inlineCompletion = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserFocusAddressBar)) { notification in
            guard let panelId = notification.object as? UUID, panelId == panel.id else { return }
            panel.beginSuppressWebViewFocusForAddressBar()
            addressBarFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserMoveOmnibarSelection)) { notification in
            guard let panelId = notification.object as? UUID, panelId == panel.id else { return }
            guard addressBarFocused, !omnibarState.suggestions.isEmpty else { return }
            guard let delta = notification.userInfo?["delta"] as? Int, delta != 0 else { return }
            let effects = omnibarReduce(state: &omnibarState, event: .moveSelection(delta: delta))
            applyOmnibarEffects(effects)
            refreshInlineCompletion()
        }
        .onReceive(BrowserHistoryStore.shared.$entries) { _ in
            guard addressBarFocused else { return }
            refreshSuggestions()
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            addressBarButtonBar

            omnibarField
                .accessibilityIdentifier("BrowserOmnibarPill")
                .accessibilityLabel("Browser omnibar")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        // Keep the omnibar stack above WKWebView so the suggestions popup is visible.
        .zIndex(1)
    }

    private var addressBarButtonBar: some View {
        let navButtonSize: CGFloat = 22

        return HStack(spacing: 0) {
            Button(action: {
                #if DEBUG
                dlog("browser.back panel=\(panel.id.uuidString.prefix(5))")
                #endif
                panel.goBack()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: navButtonSize, height: navButtonSize, alignment: .center)
            }
            .buttonStyle(.plain)
            .frame(width: navButtonSize, height: navButtonSize, alignment: .center)
            .disabled(!panel.canGoBack)
            .opacity(panel.canGoBack ? 1.0 : 0.4)
            .help("Go Back")

            Button(action: {
                #if DEBUG
                dlog("browser.forward panel=\(panel.id.uuidString.prefix(5))")
                #endif
                panel.goForward()
            }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: navButtonSize, height: navButtonSize, alignment: .center)
            }
            .buttonStyle(.plain)
            .frame(width: navButtonSize, height: navButtonSize, alignment: .center)
            .disabled(!panel.canGoForward)
            .opacity(panel.canGoForward ? 1.0 : 0.4)
            .help("Go Forward")

            Button(action: {
                if panel.isLoading {
                    #if DEBUG
                    dlog("browser.stop panel=\(panel.id.uuidString.prefix(5))")
                    #endif
                    panel.stopLoading()
                } else {
                    #if DEBUG
                    dlog("browser.reload panel=\(panel.id.uuidString.prefix(5))")
                    #endif
                    panel.reload()
                }
            }) {
                Image(systemName: panel.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: navButtonSize, height: navButtonSize, alignment: .center)
            }
            .buttonStyle(.plain)
            .frame(width: navButtonSize, height: navButtonSize, alignment: .center)
            .help(panel.isLoading ? "Stop" : "Reload")
        }
    }

    private var omnibarField: some View {
        let showSecureBadge = panel.currentURL?.scheme == "https"

        return HStack(spacing: 4) {
            if showSecureBadge {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            OmnibarTextFieldRepresentable(
                text: Binding(
                    get: { omnibarState.buffer },
                    set: { newValue in
                        let effects = omnibarReduce(state: &omnibarState, event: .bufferChanged(newValue))
                        applyOmnibarEffects(effects)
                        refreshInlineCompletion()
                    }
                ),
                isFocused: $addressBarFocused,
                inlineCompletion: inlineCompletion,
                placeholder: "Search or enter URL",
                onTap: {
                    handleOmnibarTap()
                },
                onSubmit: {
                    if addressBarFocused, !omnibarState.suggestions.isEmpty {
                        commitSelectedSuggestion()
                    } else {
                        panel.navigateSmart(omnibarState.buffer)
                        hideSuggestions()
                        suppressNextFocusLostRevert = true
                        addressBarFocused = false
                    }
                },
                onEscape: {
                    handleOmnibarEscape()
                },
                onFieldLostFocus: {
                    addressBarFocused = false
                },
                onMoveSelection: { delta in
                    guard addressBarFocused, !omnibarState.suggestions.isEmpty else { return }
                    let effects = omnibarReduce(state: &omnibarState, event: .moveSelection(delta: delta))
                    applyOmnibarEffects(effects)
                    refreshInlineCompletion()
                },
                onDeleteSelectedSuggestion: {
                    deleteSelectedSuggestionIfPossible()
                },
                onAcceptInlineCompletion: {
                    acceptInlineCompletion()
                },
                onDeleteBackwardWithInlineSelection: {
                    handleInlineBackspace()
                },
                onSelectionChanged: { selectionRange, hasMarkedText in
                    handleOmnibarSelectionChange(range: selectionRange, hasMarkedText: hasMarkedText)
                },
                shouldSuppressWebViewFocus: {
                    panel.shouldSuppressWebViewFocus()
                }
            )
                .frame(height: 18)
                .accessibilityIdentifier("BrowserOmnibarTextField")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: omnibarPillCornerRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: omnibarPillCornerRadius, style: .continuous)
                .stroke(addressBarFocused ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: OmnibarPillFramePreferenceKey.self,
                        value: geo.frame(in: .named("BrowserPanelViewSpace"))
                    )
            }
        }
    }

    private var webView: some View {
        WebViewRepresentable(
            panel: panel,
            shouldAttachWebView: isVisibleInUI,
            shouldFocusWebView: isFocused && !addressBarFocused
        )
            // Keep the representable identity stable across bonsplit structural updates.
            // This reduces WKWebView reparenting churn (and the associated WebKit crashes).
            .id(panel.id)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                // Chrome-like behavior: clicking web content while editing the
                // omnibar should commit blur and revert transient edits.
                if addressBarFocused {
                    addressBarFocused = false
                }
            })
            .zIndex(0)
            .contextMenu {
                Button("Open Developer Tools") {
                    openDevTools()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
    }

    private func triggerFocusFlashAnimation() {
        focusFlashFadeWorkItem?.cancel()
        focusFlashFadeWorkItem = nil

        withAnimation(.easeOut(duration: 0.08)) {
            focusFlashOpacity = 1.0
        }

        let item = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.35)) {
                focusFlashOpacity = 0.0
            }
        }
        focusFlashFadeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    private func syncURLFromPanel() {
        let urlString = panel.preferredURLStringForOmnibar() ?? ""
        let effects = omnibarReduce(state: &omnibarState, event: .panelURLChanged(currentURLString: urlString))
        applyOmnibarEffects(effects)
    }

    /// Treat a WebView with no URL (or about:blank) as "blank" for UX purposes.
    private func isWebViewBlank() -> Bool {
        guard let url = panel.webView.url else { return true }
        return url.absoluteString == "about:blank"
    }

    private func autoFocusOmnibarIfBlank() {
        guard isFocused else { return }
        guard !addressBarFocused else { return }
        // If a test/automation explicitly focused WebKit, don't steal focus back.
        guard !panel.shouldSuppressOmnibarAutofocus() else { return }
        // If a real navigation is underway (e.g. open_browser https://...), don't steal focus.
        guard !panel.webView.isLoading else { return }
        guard isWebViewBlank() else { return }
        addressBarFocused = true
    }

    private func openDevTools() {
        // WKWebView with developerExtrasEnabled allows right-click > Inspect Element
        // We can also trigger via JavaScript
        Task {
            try? await panel.evaluateJavaScript("window.webkit?.messageHandlers?.devTools?.postMessage('open')")
        }
    }

    private func handleOmnibarTap() {
        onRequestPanelFocus()
        guard !addressBarFocused else { return }
        // `focusPane` converges selection and can transiently move first responder to WebKit.
        // Reassert omnibar focus on the next runloop for click-to-type behavior.
        DispatchQueue.main.async {
            addressBarFocused = true
        }
    }

    private func hideSuggestions() {
        suggestionTask?.cancel()
        suggestionTask = nil
        let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated([]))
        applyOmnibarEffects(effects)
        isLoadingRemoteSuggestions = false
        inlineCompletion = nil
    }

    private func commitSelectedSuggestion() {
        let idx = omnibarState.selectedSuggestionIndex
        guard idx >= 0, idx < omnibarState.suggestions.count else { return }
        commitSuggestion(omnibarState.suggestions[idx])
    }

    private func commitSuggestion(_ suggestion: OmnibarSuggestion) {
        // Treat this as a commit, not a user edit: don't refetch suggestions while we're navigating away.
        omnibarState.buffer = suggestion.completion
        omnibarState.isUserEditing = false
        switch suggestion.kind {
        case .switchToTab(let tabId, let panelId, _, _):
            AppDelegate.shared?.tabManager?.focusTab(tabId, surfaceId: panelId)
        default:
            panel.navigateSmart(suggestion.completion)
        }
        hideSuggestions()
        inlineCompletion = nil
        suppressNextFocusLostRevert = true
        addressBarFocused = false
    }

    private func handleOmnibarEscape() {
        guard addressBarFocused else { return }

        // Chrome-like flow: clear inline completion first, then apply normal escape behavior.
        if inlineCompletion != nil {
            inlineCompletion = nil
            return
        }

        let effects = omnibarReduce(state: &omnibarState, event: .escape)
        applyOmnibarEffects(effects)
        refreshInlineCompletion()
    }

    private func handleOmnibarSelectionChange(range: NSRange, hasMarkedText: Bool) {
        omnibarSelectionRange = range
        omnibarHasMarkedText = hasMarkedText
        refreshInlineCompletion()
    }

    private func acceptInlineCompletion() {
        guard let completion = inlineCompletion else { return }
        let effects = omnibarReduce(state: &omnibarState, event: .bufferChanged(completion.displayText))
        applyOmnibarEffects(effects)
        inlineCompletion = nil
    }

    private func handleInlineBackspace() {
        guard let completion = inlineCompletion else { return }
        let prefix = completion.typedText
        guard !prefix.isEmpty else { return }
        let updated = String(prefix.dropLast())
        let effects = omnibarReduce(state: &omnibarState, event: .bufferChanged(updated))
        applyOmnibarEffects(effects)
        omnibarSelectionRange = NSRange(location: updated.utf16.count, length: 0)
        refreshInlineCompletion()
    }

    private func deleteSelectedSuggestionIfPossible() {
        let idx = omnibarState.selectedSuggestionIndex
        guard idx >= 0, idx < omnibarState.suggestions.count else { return }

        let target = omnibarState.suggestions[idx]
        guard case .history(let url, _) = target.kind else { return }
        guard BrowserHistoryStore.shared.removeHistoryEntry(urlString: url) else { return }
        refreshSuggestions()
    }

    private func refreshInlineCompletion() {
        inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: omnibarState.buffer,
            suggestions: omnibarState.suggestions,
            isFocused: addressBarFocused,
            selectionRange: omnibarSelectionRange,
            hasMarkedText: omnibarHasMarkedText
        )
    }

    private func refreshSuggestions() {
        suggestionTask?.cancel()
        suggestionTask = nil
        isLoadingRemoteSuggestions = false

        guard addressBarFocused else {
            let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated([]))
            applyOmnibarEffects(effects)
            return
        }

        let query = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let historyEntries: [BrowserHistoryStore.Entry] = {
            if query.isEmpty {
                return BrowserHistoryStore.shared.recentSuggestions(limit: 12)
            }
            return BrowserHistoryStore.shared.suggestions(for: query, limit: 12)
        }()
        let openTabMatches = query.isEmpty ? [] : matchingOpenTabSuggestions(for: query, limit: 12)
        let isSingleCharacterQuery = omnibarSingleCharacterQuery(for: query) != nil
        let staleRemote: [String]
        if query.isEmpty || isSingleCharacterQuery {
            staleRemote = []
        } else {
            staleRemote = staleRemoteSuggestionsForDisplay(query: query)
        }
        let resolvedURL = query.isEmpty ? nil : panel.resolveNavigableURL(from: query)
        let items = buildOmnibarSuggestions(
            query: query,
            engineName: searchEngine.displayName,
            historyEntries: historyEntries,
            openTabMatches: openTabMatches,
            remoteQueries: staleRemote,
            resolvedURL: resolvedURL,
            limit: 8
        )
        let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated(items))
        applyOmnibarEffects(effects)
        refreshInlineCompletion()

        guard !query.isEmpty else { return }

        if !isSingleCharacterQuery, let forcedRemote = forcedRemoteSuggestionsForUITest() {
            latestRemoteSuggestionQuery = query
            latestRemoteSuggestions = forcedRemote
            let merged = buildOmnibarSuggestions(
                query: query,
                engineName: searchEngine.displayName,
                historyEntries: historyEntries,
                openTabMatches: openTabMatches,
                remoteQueries: forcedRemote,
                resolvedURL: resolvedURL,
                limit: 8
            )
            let forcedEffects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated(merged))
            applyOmnibarEffects(forcedEffects)
            refreshInlineCompletion()
            return
        }

        guard remoteSuggestionsEnabled else { return }
        guard !isSingleCharacterQuery else { return }
        guard omnibarInputIntent(for: query) != .urlLike else { return }

        // Keep current remote rows visible while fetching fresh predictions.
        let engine = searchEngine
        isLoadingRemoteSuggestions = true
        suggestionTask = Task {
            let remote = await BrowserSearchSuggestionService.shared.suggestions(engine: engine, query: query)
            if Task.isCancelled { return }

            await MainActor.run {
                guard addressBarFocused else { return }
                let current = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard current == query else { return }
                latestRemoteSuggestionQuery = query
                latestRemoteSuggestions = remote
                let merged = buildOmnibarSuggestions(
                    query: query,
                    engineName: searchEngine.displayName,
                    historyEntries: BrowserHistoryStore.shared.suggestions(for: query, limit: 12),
                    openTabMatches: matchingOpenTabSuggestions(for: query, limit: 12),
                    remoteQueries: remote,
                    resolvedURL: panel.resolveNavigableURL(from: query),
                    limit: 8
                )
                let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated(merged))
                applyOmnibarEffects(effects)
                refreshInlineCompletion()
                isLoadingRemoteSuggestions = false
            }
        }
    }

    private func staleRemoteSuggestionsForDisplay(query: String) -> [String] {
        staleOmnibarRemoteSuggestionsForDisplay(
            query: query,
            previousRemoteQuery: latestRemoteSuggestionQuery,
            previousRemoteSuggestions: latestRemoteSuggestions
        )
    }

    private func matchingOpenTabSuggestions(for query: String, limit: Int) -> [OmnibarOpenTabMatch] {
        guard !query.isEmpty, limit > 0 else { return [] }

        let loweredQuery = query.lowercased()
        let singleCharacterQuery = omnibarSingleCharacterQuery(for: query)
        let includeCurrentPanelForSingleCharacterQuery = singleCharacterQuery != nil
        let tabManager = AppDelegate.shared?.tabManager
        let currentPanelWorkspaceId = tabManager?.tabs.first(where: { tab in
            tab.panels[panel.id] is BrowserPanel
        })?.id
        var matches: [OmnibarOpenTabMatch] = []
        var seenKeys = Set<String>()

        func preferredPanelURL(_ browserPanel: BrowserPanel) -> String? {
            browserPanel.preferredURLStringForOmnibar()
        }

        func addMatch(
            tabId: UUID,
            panelId: UUID,
            url: String,
            title: String?,
            isKnownOpenTab: Bool,
            matches: inout [OmnibarOpenTabMatch],
            seenKeys: inout Set<String>
        ) {
            let key = "\(tabId.uuidString.lowercased())|\(panelId.uuidString.lowercased())|\(url.lowercased())"
            guard !seenKeys.contains(key) else { return }
            seenKeys.insert(key)
            matches.append(
                OmnibarOpenTabMatch(
                    tabId: tabId,
                    panelId: panelId,
                    url: url,
                    title: title,
                    isKnownOpenTab: isKnownOpenTab
                )
            )
        }

        if includeCurrentPanelForSingleCharacterQuery,
           let query = singleCharacterQuery,
           let currentURL = preferredPanelURL(panel),
           !currentURL.isEmpty {
            let rawTitle = panel.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? nil : rawTitle
            if omnibarHasSingleCharacterPrefixMatch(query: query, url: currentURL, title: title) {
                addMatch(
                    tabId: currentPanelWorkspaceId ?? panel.workspaceId,
                    panelId: panel.id,
                    url: currentURL,
                    title: title,
                    isKnownOpenTab: currentPanelWorkspaceId != nil,
                    matches: &matches,
                    seenKeys: &seenKeys
                )
            }
        }

        guard let tabManager else { return matches }

        for tab in tabManager.tabs {
            for (panelId, anyPanel) in tab.panels {
                guard let browserPanel = anyPanel as? BrowserPanel else { continue }
                guard let currentURL = preferredPanelURL(browserPanel),
                      !currentURL.isEmpty else { continue }
                let isCurrentPanel = tab.id == panel.workspaceId && panelId == panel.id
                if isCurrentPanel && !includeCurrentPanelForSingleCharacterQuery {
                    continue
                }

                let rawTitle = browserPanel.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = rawTitle.isEmpty ? nil : rawTitle
                let isMatch: Bool = {
                    if let singleCharacterQuery {
                        return omnibarHasSingleCharacterPrefixMatch(
                            query: singleCharacterQuery,
                            url: currentURL,
                            title: title
                        )
                    }
                    let haystacks = [
                        currentURL.lowercased(),
                        (title ?? "").lowercased(),
                    ]
                    return haystacks.contains { $0.contains(loweredQuery) }
                }()
                guard isMatch else { continue }

                addMatch(
                    tabId: tab.id,
                    panelId: panelId,
                    url: currentURL,
                    title: title,
                    isKnownOpenTab: true,
                    matches: &matches,
                    seenKeys: &seenKeys
                )
            }
        }

        if matches.count <= limit { return matches }
        return Array(matches.prefix(limit))
    }

    private func forcedRemoteSuggestionsForUITest() -> [String]? {
        let raw = ProcessInfo.processInfo.environment["CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON"]
            ?? UserDefaults.standard.string(forKey: "CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON")
        guard let raw,
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }

        let values = parsed.compactMap { item -> String? in
            guard let s = item as? String else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return values.isEmpty ? nil : values
    }

    private func applyOmnibarEffects(_ effects: OmnibarEffects) {
        if effects.shouldRefreshSuggestions {
            refreshSuggestions()
        }
        if effects.shouldSelectAll {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
        if effects.shouldBlurToWebView {
            hideSuggestions()
            addressBarFocused = false
            DispatchQueue.main.async {
                guard isFocused else { return }
                guard let window = panel.webView.window,
                      !panel.webView.isHiddenOrHasHiddenAncestor else { return }
                panel.clearWebViewFocusSuppression()
                window.makeFirstResponder(panel.webView)
                NotificationCenter.default.post(name: .browserDidExitAddressBar, object: panel.id)
            }
        }
    }
}

enum OmnibarInputIntent: Equatable {
    case urlLike
    case queryLike
    case ambiguous
}

    struct OmnibarOpenTabMatch: Equatable {
        let tabId: UUID
        let panelId: UUID
        let url: String
        let title: String?
        let isKnownOpenTab: Bool

        init(tabId: UUID, panelId: UUID, url: String, title: String?, isKnownOpenTab: Bool = true) {
            self.tabId = tabId
            self.panelId = panelId
            self.url = url
            self.title = title
            self.isKnownOpenTab = isKnownOpenTab
        }
    }

func omnibarInputIntent(for query: String) -> OmnibarInputIntent {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .ambiguous }

    if resolveBrowserNavigableURL(trimmed) != nil {
        return .urlLike
    }

    if trimmed.contains(" ") {
        return .queryLike
    }

    if trimmed.contains(".") {
        return .ambiguous
    }

    return .queryLike
}

func omnibarSuggestionCompletion(for suggestion: OmnibarSuggestion) -> String? {
    switch suggestion.kind {
    case .navigate(let url):
        return url
    case .history(let url, _):
        return url
    case .switchToTab(_, _, let url, _):
        return url
    default:
        return nil
    }
}

func omnibarSuggestionTitle(for suggestion: OmnibarSuggestion) -> String? {
    switch suggestion.kind {
    case .history(_, let title):
        return title
    case .switchToTab(_, _, _, let title):
        return title
    default:
        return nil
    }
}

func omnibarSuggestionMatchesTypedPrefix(
    typedText: String,
    suggestionCompletion: String,
    suggestionTitle: String? = nil
) -> Bool {
    let trimmedQuery = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return false }

    let query = trimmedQuery.lowercased()
    let trimmedCompletion = suggestionCompletion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCompletion.isEmpty else { return false }
    let loweredCompletion = trimmedCompletion.lowercased()

    let schemeStripped = stripHTTPSchemePrefix(trimmedCompletion)
    let schemeAndWWWStripped = stripHTTPSchemeAndWWWPrefix(trimmedCompletion)
    let typedIncludesScheme = query.hasPrefix("https://") || query.hasPrefix("http://")
    let typedIncludesWWWPrefix = query.hasPrefix("www.")

    if typedIncludesScheme, loweredCompletion.hasPrefix(query) { return true }
    if schemeStripped.hasPrefix(query) { return true }
    if !typedIncludesWWWPrefix && schemeAndWWWStripped.hasPrefix(query) { return true }

    let normalizedTitle = suggestionTitle?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    if !normalizedTitle.isEmpty && normalizedTitle.hasPrefix(query) {
        return true
    }

    return false
}

func omnibarSuggestionSupportsAutocompletion(query: String, suggestion: OmnibarSuggestion) -> Bool {
    if case .search = suggestion.kind { return false }
    if case .remote = suggestion.kind { return false }
    guard let completion = omnibarSuggestionCompletion(for: suggestion) else { return false }
    // Reject URLs whose host lacks a TLD (e.g. "https://news." → host "news").
    if let components = URLComponents(string: completion),
       let host = components.host?.lowercased() {
        let trimmedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        if !trimmedHost.contains(".") { return false }
    }
    let title = omnibarSuggestionTitle(for: suggestion)
    return omnibarSuggestionMatchesTypedPrefix(
        typedText: query,
        suggestionCompletion: completion,
        suggestionTitle: title
    )
}

func omnibarSingleCharacterQuery(for query: String) -> String? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.utf16.count == 1 else { return nil }
    return trimmed
}

func omnibarStrippedURL(_ value: String) -> String {
    return stripHTTPSchemeAndWWWPrefix(value)
}

func omnibarScoringCandidate(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    if let components = URLComponents(string: trimmed), let host = components.host?.lowercased() {
        let hostWithoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let normalizedScheme = components.scheme?.lowercased()
        let isDefaultPort = (normalizedScheme == "http" && components.port == 80)
            || (normalizedScheme == "https" && components.port == 443)
        let portSuffix = {
            guard let port = components.port, !isDefaultPort else { return "" }
            return ":\(port)"
        }()

        var normalized = "\(hostWithoutWWW)\(portSuffix)"
        let path = components.percentEncodedPath
        if !path.isEmpty && path != "/" {
            normalized += path
        } else if path == "/" {
            normalized += "/"
        }

        if let query = components.percentEncodedQuery, !query.isEmpty {
            normalized += "?\(query)"
        }
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            normalized += "#\(fragment)"
        }
        return normalized
    }

    return stripHTTPSchemeAndWWWPrefix(trimmed)
}

func omnibarHasSingleCharacterPrefixMatch(query: String, url: String, title: String?) -> Bool {
    guard let trimmedQuery = omnibarSingleCharacterQuery(for: query) else { return false }

    let normalizedURL = omnibarStrippedURL(url).lowercased()
    let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return normalizedURL.hasPrefix(trimmedQuery) || normalizedTitle.hasPrefix(trimmedQuery)
}

func buildOmnibarSuggestions(
    query: String,
    engineName: String,
    historyEntries: [BrowserHistoryStore.Entry],
    openTabMatches: [OmnibarOpenTabMatch] = [],
    remoteQueries: [String],
    resolvedURL: URL?,
    limit: Int = 8,
    now: Date = Date()
) -> [OmnibarSuggestion] {
    guard limit > 0 else { return [] }

    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedQuery.isEmpty {
        return Array(historyEntries.prefix(limit).map { .history($0) })
    }
    let singleCharacterQuery = omnibarSingleCharacterQuery(for: trimmedQuery)
    let isSingleCharacterQuery = singleCharacterQuery != nil
    let shouldIncludeRemoteSuggestions = !isSingleCharacterQuery
    let filteredHistoryEntries: [BrowserHistoryStore.Entry]
    let filteredOpenTabMatches: [OmnibarOpenTabMatch]
    if let singleCharacterQuery {
        filteredHistoryEntries = historyEntries.filter {
            omnibarHasSingleCharacterPrefixMatch(query: singleCharacterQuery, url: $0.url, title: $0.title)
        }
        filteredOpenTabMatches = openTabMatches.filter {
            omnibarHasSingleCharacterPrefixMatch(query: singleCharacterQuery, url: $0.url, title: $0.title)
        }
    } else {
        filteredHistoryEntries = historyEntries
        filteredOpenTabMatches = openTabMatches
    }

    let shouldSuppressSingleCharacterSearchResult = isSingleCharacterQuery
        && (!filteredHistoryEntries.isEmpty || !filteredOpenTabMatches.isEmpty)

    struct RankedSuggestion {
        let suggestion: OmnibarSuggestion
        let score: Double
        let order: Int
        let isAutocompletableMatch: Bool
        let kindPriority: Int
    }

    var bestByCompletion: [String: RankedSuggestion] = [:]
    var order = 0
    let intent = omnibarInputIntent(for: trimmedQuery)
    let normalizedQuery = trimmedQuery.lowercased()

    func suggestionPriority(for kind: OmnibarSuggestion.Kind) -> Int {
        switch kind {
        case .search:
            return 300
        case .remote:
            return 350
        default:
            return 0
        }
    }

    func completionScore(for candidate: String) -> Double {
        let c = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let q = normalizedQuery
        guard !c.isEmpty, !q.isEmpty else { return 0 }

        let scoringCandidate = omnibarScoringCandidate(c)
        if !scoringCandidate.isEmpty {
            if scoringCandidate == q { return 260 }
            if scoringCandidate.hasPrefix(q) { return 220 }
            if scoringCandidate.contains(q) { return 150 }
        }

        if c == q { return 240 }
        if c.hasPrefix(q) { return 170 }
        if c.contains(q) { return 95 }
        return 0
    }

    func insert(_ suggestion: OmnibarSuggestion, score: Double) {
        let key = suggestion.completion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        let isAutocompletableMatch = omnibarSuggestionSupportsAutocompletion(query: trimmedQuery, suggestion: suggestion)

        let ranked = RankedSuggestion(
            suggestion: suggestion,
            score: score,
            order: order,
            isAutocompletableMatch: isAutocompletableMatch,
            kindPriority: suggestionPriority(for: suggestion.kind)
        )
        order += 1
        if let existing = bestByCompletion[key] {
            if ranked.score > existing.score {
                bestByCompletion[key] = ranked
            }
        } else {
            bestByCompletion[key] = ranked
        }
    }

    if !(isSingleCharacterQuery && shouldSuppressSingleCharacterSearchResult) {
        let searchBaseScore: Double
        switch intent {
        case .queryLike: searchBaseScore = 820
        case .ambiguous: searchBaseScore = 540
        case .urlLike: searchBaseScore = 140
        }
        insert(.search(engineName: engineName, query: trimmedQuery), score: searchBaseScore + completionScore(for: trimmedQuery))
    }

    if let resolvedURL {
        let completion = resolvedURL.absoluteString
        let navigateBaseScore: Double
        switch intent {
        case .urlLike: navigateBaseScore = 1_020
        case .ambiguous: navigateBaseScore = 760
        case .queryLike: navigateBaseScore = 470
        }
        insert(.navigate(url: completion), score: navigateBaseScore + completionScore(for: completion))
    }

    for (index, entry) in filteredHistoryEntries.prefix(max(limit * 2, limit)).enumerated() {
        let intentBaseScore: Double
        switch intent {
        case .urlLike: intentBaseScore = 780
        case .ambiguous: intentBaseScore = 690
        case .queryLike: intentBaseScore = 600
        }
        let urlMatch = completionScore(for: entry.url)
        let titleMatch = completionScore(for: entry.title ?? "") * 0.6
        let ageHours = max(0, now.timeIntervalSince(entry.lastVisited) / 3600)
        let recencyScore = max(0, 75 - (ageHours / 5))
        let visitScore = min(95, log1p(Double(max(1, entry.visitCount))) * 32)
        let typedScore = min(230, log1p(Double(max(0, entry.typedCount))) * 100)
        let typedRecencyScore: Double
        if let lastTypedAt = entry.lastTypedAt {
            let typedAgeHours = max(0, now.timeIntervalSince(lastTypedAt) / 3600)
            typedRecencyScore = max(0, 80 - (typedAgeHours / 5))
        } else {
            typedRecencyScore = 0
        }
        let positionScore = Double(max(0, 16 - index))
        let total = intentBaseScore + urlMatch + titleMatch + recencyScore + visitScore + typedScore + typedRecencyScore + positionScore
        insert(.history(entry), score: total)
    }

    for (index, match) in filteredOpenTabMatches.prefix(limit).enumerated() {
        let intentBaseScore: Double
        switch intent {
        case .urlLike: intentBaseScore = 1_180
        case .ambiguous: intentBaseScore = 980
        case .queryLike: intentBaseScore = 820
        }
        let urlMatch = completionScore(for: match.url)
        let titleMatch = completionScore(for: match.title ?? "") * 0.65
        let positionScore = Double(max(0, 14 - index)) * 0.9
        let resolvedURLBonus: Double
        if let resolvedURL,
           resolvedURL.absoluteString.caseInsensitiveCompare(match.url) == .orderedSame {
            resolvedURLBonus = 120
        } else {
            resolvedURLBonus = 0
        }
        let total = intentBaseScore + urlMatch + titleMatch + positionScore + resolvedURLBonus
        if match.isKnownOpenTab {
            insert(
                .switchToTab(tabId: match.tabId, panelId: match.panelId, url: match.url, title: match.title),
                score: total
            )
        } else {
            insert(
                OmnibarSuggestion.history(url: match.url, title: match.title),
                score: total
            )
        }
    }

    if shouldIncludeRemoteSuggestions {
        for (index, remoteQuery) in remoteQueries.prefix(limit).enumerated() {
            let trimmedRemote = remoteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRemote.isEmpty else { continue }

            let remoteBaseScore: Double
            switch intent {
            case .queryLike: remoteBaseScore = 690
            case .ambiguous: remoteBaseScore = 450
            case .urlLike: remoteBaseScore = 110
            }
            let positionScore = Double(max(0, 14 - index)) * 0.9
            let total = remoteBaseScore + completionScore(for: trimmedRemote) + positionScore
            insert(.remoteSearchSuggestion(trimmedRemote), score: total)
        }
    }

    let sorted = bestByCompletion.values.sorted { lhs, rhs in
        if lhs.isAutocompletableMatch != rhs.isAutocompletableMatch {
            return lhs.isAutocompletableMatch
        }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.kindPriority != rhs.kindPriority {
            return lhs.kindPriority < rhs.kindPriority
        }
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.suggestion.completion < rhs.suggestion.completion
    }
    let suggestions = Array(sorted.map(\.suggestion).prefix(limit))
    return prioritizedAutocompletionSuggestions(suggestions: Array(suggestions), for: trimmedQuery)
}

private func prioritizedAutocompletionSuggestions(suggestions: [OmnibarSuggestion], for query: String) -> [OmnibarSuggestion] {
    guard let preferred = omnibarPreferredAutocompletionSuggestionIndex(
        suggestions: suggestions,
        query: query
    ) else {
        return suggestions
    }

    guard preferred != 0 else { return suggestions }

    var reordered = suggestions
    let suggestion = reordered.remove(at: preferred)
    reordered.insert(suggestion, at: 0)
    return reordered
}

private func omnibarPreferredAutocompletionSuggestionIndex(
    suggestions: [OmnibarSuggestion],
    query: String
) -> Int? {
    guard !query.isEmpty else { return nil }

    var candidates: [(idx: Int, suffixLength: Int)] = []
    for (idx, suggestion) in suggestions.enumerated() {
        guard omnibarSuggestionSupportsAutocompletion(query: query, suggestion: suggestion) else { continue }
        guard let completion = omnibarSuggestionCompletion(for: suggestion) else { continue }
        let displayCompletion = omnibarSuggestionMatchesTypedPrefix(
            typedText: query,
            suggestionCompletion: completion,
            suggestionTitle: omnibarSuggestionTitle(for: suggestion)
        ) ? completion : ""
        guard !displayCompletion.isEmpty else { continue }

        let suffixLength = max(
            0,
            omnibarSuggestionDisplayText(forPrefixing: displayCompletion, query: query).utf16.count - query.utf16.count
        )
        candidates.append((idx: idx, suffixLength: suffixLength))
    }

    guard let preferred = candidates.min(by: {
        if $0.suffixLength != $1.suffixLength {
            return $0.suffixLength < $1.suffixLength
        }
        return $0.idx < $1.idx
    })?.idx else {
        return nil
    }

    return preferred
}

private func omnibarSuggestionDisplayText(forPrefixing completion: String, query: String) -> String {
    let typedIncludesScheme = query.hasPrefix("https://") || query.hasPrefix("http://")
    let typedIncludesWWWPrefix = query.hasPrefix("www.")
    if typedIncludesScheme {
        return completion
    }
    if typedIncludesWWWPrefix {
        return stripHTTPSchemePrefix(completion)
    }
    return stripHTTPSchemeAndWWWPrefix(completion)
}

func staleOmnibarRemoteSuggestionsForDisplay(
    query: String,
    previousRemoteQuery: String,
    previousRemoteSuggestions: [String],
    limit: Int = 8
) -> [String] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPreviousQuery = previousRemoteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let loweredQuery = trimmedQuery.lowercased()
    let loweredPreviousQuery = trimmedPreviousQuery.lowercased()
    guard !trimmedQuery.isEmpty, !trimmedPreviousQuery.isEmpty else { return [] }
    guard loweredQuery == loweredPreviousQuery || loweredQuery.hasPrefix(loweredPreviousQuery) || loweredPreviousQuery.hasPrefix(loweredQuery) else {
        return []
    }
    guard !previousRemoteSuggestions.isEmpty else { return [] }
    let sanitized = previousRemoteSuggestions.compactMap { raw -> String? in
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    if sanitized.isEmpty {
        return []
    }
    return Array(sanitized.prefix(limit))
}

func omnibarInlineCompletionForDisplay(
    typedText: String,
    suggestions: [OmnibarSuggestion],
    isFocused: Bool,
    selectionRange: NSRange,
    hasMarkedText: Bool
) -> OmnibarInlineCompletion? {
    guard isFocused else { return nil }
    guard !hasMarkedText else { return nil }

    let query = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    let loweredQuery = query.lowercased()
    let typedIncludesScheme = loweredQuery.hasPrefix("https://") || loweredQuery.hasPrefix("http://")
    let typedIncludesWWWPrefix = loweredQuery.hasPrefix("www.")
    let queryCount = query.utf16.count

    let urlCandidate = suggestions.first { suggestion in
        guard let completion = omnibarSuggestionCompletion(for: suggestion) else { return false }
        return omnibarSuggestionMatchesTypedPrefix(
            typedText: query,
            suggestionCompletion: completion,
            suggestionTitle: omnibarSuggestionTitle(for: suggestion)
        )
    }
    guard let candidate = urlCandidate else {
        return nil
    }

    let acceptedText = candidate.completion
    let displayText: String
    if typedQueryHasExplicitPathOrQuery(query) {
        if typedIncludesScheme {
            displayText = acceptedText
        } else if typedIncludesWWWPrefix {
            displayText = stripHTTPSchemePrefix(acceptedText)
        } else {
            displayText = stripHTTPSchemeAndWWWPrefix(acceptedText)
        }
    } else if let hostOnlyDisplay = inlineCompletionHostDisplayText(
        for: acceptedText,
        typedIncludesScheme: typedIncludesScheme,
        typedIncludesWWWPrefix: typedIncludesWWWPrefix
    ) {
        displayText = hostOnlyDisplay
    } else {
        if typedIncludesScheme {
            displayText = acceptedText
        } else if typedIncludesWWWPrefix {
            displayText = stripHTTPSchemePrefix(acceptedText)
        } else {
            displayText = stripHTTPSchemeAndWWWPrefix(acceptedText)
        }
    }

    guard omnibarSuggestionSupportsAutocompletion(query: query, suggestion: candidate) else { return nil }
    guard displayText.utf16.count > queryCount else {
        return nil
    }

    let displayCount = displayText.utf16.count

    let resolvedSelectionRange: NSRange = {
        if selectionRange.location == NSNotFound {
            return NSRange(location: queryCount, length: 0)
        }
        let clampedLocation = min(selectionRange.location, displayCount)
        let remaining = max(0, displayCount - clampedLocation)
        let clampedLength = min(selectionRange.length, remaining)
        return NSRange(location: clampedLocation, length: clampedLength)
    }()

    let suffixRange = NSRange(location: queryCount, length: max(0, displayCount - queryCount))
    let isCaretAtTypedBoundary = (resolvedSelectionRange.length == 0 && resolvedSelectionRange.location == queryCount)
    let isSuffixSelection = NSEqualRanges(resolvedSelectionRange, suffixRange)
    let isSelectAllSelection = (resolvedSelectionRange.location == 0 && resolvedSelectionRange.length == displayCount)
    // Command+A can briefly report just the typed prefix selection before the full
    // select-all range lands. Keep inline completion alive through that transition.
    let typedPrefixSelection = NSRange(location: 0, length: queryCount)
    let isTypedPrefixSelection = NSEqualRanges(resolvedSelectionRange, typedPrefixSelection)
    guard isCaretAtTypedBoundary || isSuffixSelection || isSelectAllSelection || isTypedPrefixSelection else {
        return nil
    }

    return OmnibarInlineCompletion(typedText: query, displayText: displayText, acceptedText: acceptedText)
}

func omnibarDesiredSelectionRangeForInlineCompletion(
    currentSelection: NSRange,
    inlineCompletion: OmnibarInlineCompletion
) -> NSRange {
    let typedCount = inlineCompletion.typedText.utf16.count
    let typedPrefixSelection = NSRange(location: 0, length: typedCount)
    let displayCount = inlineCompletion.displayText.utf16.count
    let isSelectAll = currentSelection.location == 0 && currentSelection.length == displayCount
    if isSelectAll ||
        NSEqualRanges(currentSelection, inlineCompletion.suffixRange) ||
        NSEqualRanges(currentSelection, typedPrefixSelection) {
        return currentSelection
    }
    return inlineCompletion.suffixRange
}

private func typedQueryHasExplicitPathOrQuery(_ typedQuery: String) -> Bool {
    var normalized = typedQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("https://") {
        normalized.removeFirst("https://".count)
    } else if normalized.hasPrefix("http://") {
        normalized.removeFirst("http://".count)
    }
    return normalized.contains("/") || normalized.contains("?") || normalized.contains("#")
}

private func inlineCompletionHostDisplayText(
    for acceptedText: String,
    typedIncludesScheme: Bool,
    typedIncludesWWWPrefix: Bool
) -> String? {
    guard let components = URLComponents(string: acceptedText),
          var host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !host.isEmpty else {
        return nil
    }

    if !typedIncludesWWWPrefix, host.hasPrefix("www.") {
        host.removeFirst("www.".count)
    }

    let portSuffix: String
    if let port = components.port {
        let scheme = components.scheme?.lowercased()
        let isDefaultPort =
            (scheme == "https" && port == 443) ||
            (scheme == "http" && port == 80)
        portSuffix = isDefaultPort ? "" : ":\(port)"
    } else {
        portSuffix = ""
    }

    let hostWithPort = "\(host)\(portSuffix)"
    if typedIncludesScheme {
        let scheme = (components.scheme?.lowercased() == "http") ? "http" : "https"
        return "\(scheme)://\(hostWithPort)"
    }
    return hostWithPort
}

private func stripHTTPSchemePrefix(_ raw: String) -> String {
    var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("https://") {
        normalized.removeFirst("https://".count)
    } else if normalized.hasPrefix("http://") {
        normalized.removeFirst("http://".count)
    }
    return normalized
}

private func stripHTTPSchemeAndWWWPrefix(_ raw: String) -> String {
    var normalized = stripHTTPSchemePrefix(raw)
    if normalized.hasPrefix("www.") {
        normalized.removeFirst("www.".count)
    }
    return normalized
}

private struct OmnibarPillFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

// MARK: - Omnibar State Machine

struct OmnibarState: Equatable {
    var isFocused: Bool = false
    var currentURLString: String = ""
    var buffer: String = ""
    var suggestions: [OmnibarSuggestion] = []
    var selectedSuggestionIndex: Int = 0
    var selectedSuggestionID: String?
    var isUserEditing: Bool = false
}

enum OmnibarEvent: Equatable {
    case focusGained(currentURLString: String)
    case focusLostRevertBuffer(currentURLString: String)
    case focusLostPreserveBuffer(currentURLString: String)
    case panelURLChanged(currentURLString: String)
    case bufferChanged(String)
    case suggestionsUpdated([OmnibarSuggestion])
    case moveSelection(delta: Int)
    case highlightIndex(Int)
    case escape
}

struct OmnibarEffects: Equatable {
    var shouldSelectAll: Bool = false
    var shouldBlurToWebView: Bool = false
    var shouldRefreshSuggestions: Bool = false
}

@discardableResult
func omnibarReduce(state: inout OmnibarState, event: OmnibarEvent) -> OmnibarEffects {
    var effects = OmnibarEffects()

    switch event {
    case .focusGained(let url):
        state.isFocused = true
        state.currentURLString = url
        state.buffer = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0
        state.selectedSuggestionID = nil
        effects.shouldSelectAll = true

    case .focusLostRevertBuffer(let url):
        state.isFocused = false
        state.currentURLString = url
        state.buffer = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0
        state.selectedSuggestionID = nil

    case .focusLostPreserveBuffer(let url):
        state.isFocused = false
        state.currentURLString = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0
        state.selectedSuggestionID = nil

    case .panelURLChanged(let url):
        state.currentURLString = url
        if !state.isUserEditing {
            state.buffer = url
            state.suggestions = []
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
        }

    case .bufferChanged(let newValue):
        state.buffer = newValue
        if state.isFocused {
            state.isUserEditing = (newValue != state.currentURLString)
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
            effects.shouldRefreshSuggestions = true
        }

    case .suggestionsUpdated(let items):
        let previousItems = state.suggestions
        let previousSelectedID = state.selectedSuggestionID
        state.suggestions = items
        if items.isEmpty {
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
        } else if let previousSelectedID,
                  let existingIdx = items.firstIndex(where: { $0.id == previousSelectedID }) {
            state.selectedSuggestionIndex = existingIdx
            state.selectedSuggestionID = items[existingIdx].id
        } else if let preferredSuggestionIndex = omnibarPreferredAutocompletionSuggestionIndex(
            suggestions: items,
            query: state.buffer
        ) {
            state.selectedSuggestionIndex = preferredSuggestionIndex
            state.selectedSuggestionID = items[preferredSuggestionIndex].id
        } else if previousItems.isEmpty {
            // Popup reopened: start keyboard focus from the first row.
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = items[0].id
        } else if let previousSelectedID,
                  let idx = items.firstIndex(where: { $0.id == previousSelectedID }) {
            state.selectedSuggestionIndex = idx
            state.selectedSuggestionID = items[idx].id
        } else {
            state.selectedSuggestionIndex = min(max(0, state.selectedSuggestionIndex), items.count - 1)
            state.selectedSuggestionID = items[state.selectedSuggestionIndex].id
        }

    case .moveSelection(let delta):
        guard !state.suggestions.isEmpty else { break }
        state.selectedSuggestionIndex = min(
            max(0, state.selectedSuggestionIndex + delta),
            state.suggestions.count - 1
        )
        state.selectedSuggestionID = state.suggestions[state.selectedSuggestionIndex].id

    case .highlightIndex(let idx):
        guard !state.suggestions.isEmpty else { break }
        state.selectedSuggestionIndex = min(max(0, idx), state.suggestions.count - 1)
        state.selectedSuggestionID = state.suggestions[state.selectedSuggestionIndex].id

    case .escape:
        guard state.isFocused else { break }
        // Chrome semantics:
        // - If user input is in progress OR the popup is open: revert to the page URL and select-all.
        // - Otherwise: exit omnibar focus.
        if state.isUserEditing || !state.suggestions.isEmpty {
            state.isUserEditing = false
            state.buffer = state.currentURLString
            state.suggestions = []
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
            effects.shouldSelectAll = true
        } else {
            effects.shouldBlurToWebView = true
        }
    }

    return effects
}

struct OmnibarSuggestion: Identifiable, Hashable {
    enum Kind: Hashable {
        case search(engineName: String, query: String)
        case navigate(url: String)
        case history(url: String, title: String?)
        case switchToTab(tabId: UUID, panelId: UUID, url: String, title: String?)
        case remote(query: String)
    }

    let kind: Kind

    // Stable identity prevents row teardown/rebuild flicker while typing.
    var id: String {
        switch kind {
        case .search(let engineName, let query):
            return "search|\(engineName.lowercased())|\(query.lowercased())"
        case .navigate(let url):
            return "navigate|\(url.lowercased())"
        case .history(let url, _):
            return "history|\(url.lowercased())"
        case .switchToTab(let tabId, let panelId, let url, _):
            return "switch-tab|\(tabId.uuidString.lowercased())|\(panelId.uuidString.lowercased())|\(url.lowercased())"
        case .remote(let query):
            return "remote|\(query.lowercased())"
        }
    }

    var completion: String {
        switch kind {
        case .search(_, let q): return q
        case .navigate(let url): return url
        case .history(let url, _): return url
        case .switchToTab(_, _, let url, _): return url
        case .remote(let q): return q
        }
    }

    var primaryText: String {
        switch kind {
        case .search(let engineName, let q):
            return "Search \(engineName) for \"\(q)\""
        case .navigate(let url):
            return Self.displayURLText(for: url)
        case .history(let url, let title):
            return (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? Self.singleLineText(title) : Self.displayURLText(for: url)
        case .switchToTab(_, _, let url, let title):
            return (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? Self.singleLineText(title) : Self.displayURLText(for: url)
        case .remote(let q):
            return q
        }
    }

    var listText: String {
        switch kind {
        case .history(let url, let title), .switchToTab(_, _, let url, let title):
            let titleOneline = Self.singleLineText(title)
            guard !titleOneline.isEmpty else { return Self.displayURLText(for: url) }
            return "\(titleOneline) — \(Self.displayURLText(for: url))"
        default:
            return primaryText
        }
    }

    var secondaryText: String? {
        switch kind {
        case .history(let url, let title):
            let titleOneline = Self.singleLineText(title)
            return titleOneline.isEmpty ? nil : Self.displayURLText(for: url)
        case .switchToTab(_, _, let url, let title):
            let titleOneline = Self.singleLineText(title)
            return titleOneline.isEmpty ? nil : Self.displayURLText(for: url)
        default:
            return nil
        }
    }

    var trailingBadgeText: String? {
        switch kind {
        case .switchToTab:
            return "Switch to tab"
        default:
            return nil
        }
    }

    var isHistoryRemovable: Bool {
        if case .history = kind { return true }
        return false
    }

    static func history(_ entry: BrowserHistoryStore.Entry) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .history(url: entry.url, title: entry.title))
    }

    static func history(url: String, title: String?) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .history(url: url, title: title))
    }

    static func search(engineName: String, query: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .search(engineName: engineName, query: query))
    }

    static func navigate(url: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .navigate(url: url))
    }

    static func switchToTab(tabId: UUID, panelId: UUID, url: String, title: String?) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .switchToTab(tabId: tabId, panelId: panelId, url: url, title: title))
    }

    private static func singleLineText(_ value: String?) -> String {
        var normalized = (value ?? "").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.contains("  ") {
            let collapsed = normalized.replacingOccurrences(of: "  ", with: " ")
            if collapsed == normalized { break }
            normalized = collapsed
        }
        return normalized
    }

    static func remoteSearchSuggestion(_ query: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .remote(query: query))
    }

    private static func displayURLText(for rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL),
              var host = components.host else {
            return rawURL
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        host = host.lowercased()

        var result = host
        if let port = components.port {
            result += ":\(port)"
        }

        let path = components.percentEncodedPath
        if !path.isEmpty, path != "/" {
            result += path
        } else if path == "/" {
            result += "/"
        }

        if let query = components.percentEncodedQuery, !query.isEmpty {
            result += "?\(query)"
        }

        if result.isEmpty { return rawURL }
        return result
    }
}

private final class OmnibarNativeTextField: NSTextField {
    var onPointerDown: (() -> Void)?
    var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        dlog("browser.omnibarClick")
        #endif
        onPointerDown?()

        if currentEditor() == nil {
            // First click — activate editing and select all (standard URL bar behavior).
            // Avoids NSTextView's tracking loop which can spin forever if text layout
            // enters an infinite invalidation cycle (e.g. under memory pressure).
            window?.makeFirstResponder(self)
            currentEditor()?.selectAll(nil)
        } else {
            // Already editing — allow normal click-to-place-cursor and drag-to-select.
            // Guard against a stuck tracking loop by posting a synthetic mouseUp after
            // a timeout so the main thread can't be blocked indefinitely.
            var trackingFinished = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard !trackingFinished, let self, let window = self.window else { return }
                #if DEBUG
                dlog("browser.omnibarTrackingTimeout — forcing mouseUp")
                #endif
                if let fakeUp = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: event.locationInWindow,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 0.0
                ) {
                    NSApp.postEvent(fakeUp, atStart: true)
                }
            }
            super.mouseDown(with: event)
            trackingFinished = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct OmnibarTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let inlineCompletion: OmnibarInlineCompletion?
    let placeholder: String
    let onTap: () -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onFieldLostFocus: () -> Void
    let onMoveSelection: (Int) -> Void
    let onDeleteSelectedSuggestion: () -> Void
    let onAcceptInlineCompletion: () -> Void
    let onDeleteBackwardWithInlineSelection: () -> Void
    let onSelectionChanged: (NSRange, Bool) -> Void
    let shouldSuppressWebViewFocus: () -> Bool

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmnibarTextFieldRepresentable
        var isProgrammaticMutation: Bool = false
        var selectionObserver: NSObjectProtocol?
        weak var observedEditor: NSTextView?
        var appliedInlineCompletion: OmnibarInlineCompletion?
        var lastPublishedSelection: NSRange = NSRange(location: NSNotFound, length: 0)
        var lastPublishedHasMarkedText: Bool = false

        init(parent: OmnibarTextFieldRepresentable) {
            self.parent = parent
        }

        deinit {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if !parent.isFocused {
                DispatchQueue.main.async {
                    self.parent.isFocused = true
                }
            }
            attachSelectionObserverIfNeeded()
            publishSelectionState()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if parent.isFocused {
                if parent.shouldSuppressWebViewFocus() {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard self.parent.isFocused else { return }
                        guard self.parent.shouldSuppressWebViewFocus() else { return }
                        guard let field = self.parentField, let window = field.window else { return }
                        // Check both the field itself AND its field editor (which becomes
                        // the actual first responder when the text field is being edited).
                        let fr = window.firstResponder
                        let isAlreadyFocused = fr === field ||
                            ((fr as? NSTextView)?.delegate as? NSTextField) === field
                        if !isAlreadyFocused {
                            window.makeFirstResponder(field)
                        }
                    }
                    return
                }
                parent.onFieldLostFocus()
            }
            detachSelectionObserver()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            publishSelectionState()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(+1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
                if parent.inlineCompletion != nil {
                    parent.onAcceptInlineCompletion()
                    return true
                }
                return false
            case #selector(NSResponder.insertTab(_:)):
                if parent.inlineCompletion != nil {
                    parent.onAcceptInlineCompletion()
                    return true
                }
                return false
            case #selector(NSResponder.deleteBackward(_:)):
                if suffixSelectionMatchesInline(textView, inline: parent.inlineCompletion) {
                    parent.onDeleteBackwardWithInlineSelection()
                    return true
                }
                return false
            default:
                return false
            }
        }

        func attachSelectionObserverIfNeeded() {
            guard selectionObserver == nil else { return }
            guard let field = parentField else { return }
            guard let editor = field.currentEditor() as? NSTextView else { return }
            observedEditor = editor
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: editor,
                queue: .main
            ) { [weak self] _ in
                self?.publishSelectionState()
            }
        }

        func detachSelectionObserver() {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
                self.selectionObserver = nil
            }
            observedEditor = nil
        }

        weak var parentField: OmnibarNativeTextField?

        func publishSelectionState() {
            guard let field = parentField else { return }
            if let editor = field.currentEditor() as? NSTextView {
                let range = editor.selectedRange()
                let hasMarkedText = editor.hasMarkedText()
                guard !NSEqualRanges(range, lastPublishedSelection) || hasMarkedText != lastPublishedHasMarkedText else {
                    return
                }
                lastPublishedSelection = range
                lastPublishedHasMarkedText = hasMarkedText
                parent.onSelectionChanged(range, hasMarkedText)
            } else {
                let location = field.stringValue.utf16.count
                let range = NSRange(location: location, length: 0)
                guard !NSEqualRanges(range, lastPublishedSelection) || lastPublishedHasMarkedText else { return }
                lastPublishedSelection = range
                lastPublishedHasMarkedText = false
                parent.onSelectionChanged(range, false)
            }
        }

    private func suffixSelectionMatchesInline(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
        guard let editor, let inline else { return false }
        let selected = editor.selectedRange()
        return NSEqualRanges(selected, inline.suffixRange)
    }

    private func selectionIsTypedPrefixBoundary(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
        guard let editor, let inline else { return false }
        let selected = editor.selectedRange()
        let typedCount = inline.typedText.utf16.count
        return selected.location == typedCount && selected.length == 0
    }

        func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .control, .shift, .option, .function])
            let lowered = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let hasCommandOrControl = modifiers.contains(.command) || modifiers.contains(.control)

            // Cmd/Ctrl+N and Cmd/Ctrl+P should repeat while held.
            if hasCommandOrControl, lowered == "n" {
                parent.onMoveSelection(+1)
                return true
            }
            if hasCommandOrControl, lowered == "p" {
                parent.onMoveSelection(-1)
                return true
            }

            // Shift+Delete removes the selected history suggestion when possible.
            if modifiers.contains(.shift), (keyCode == 51 || keyCode == 117) {
                parent.onDeleteSelectedSuggestion()
                return true
            }

            switch keyCode {
            case 36, 76: // Return / keypad Enter
                parent.onSubmit()
                return true
            case 53: // Escape
                parent.onEscape()
                return true
            case 125: // Down
                parent.onMoveSelection(+1)
                return true
            case 126: // Up
                parent.onMoveSelection(-1)
                return true
            case 124, 119: // Right arrow / End
                if parent.inlineCompletion != nil {
                    parent.onAcceptInlineCompletion()
                    return true
                }
            case 48: // Tab
                if parent.inlineCompletion != nil {
                    parent.onAcceptInlineCompletion()
                    return true
                }
            case 51: // Backspace
                if let inline = parent.inlineCompletion,
                   (suffixSelectionMatchesInline(editor, inline: inline) || selectionIsTypedPrefixBoundary(editor, inline: inline)) {
                    parent.onDeleteBackwardWithInlineSelection()
                    return true
                }
            default:
                break
            }

            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> OmnibarNativeTextField {
        let field = OmnibarNativeTextField(frame: .zero)
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = nil
        field.action = nil
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.stringValue = text
        field.onPointerDown = {
            onTap()
        }
        field.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
            coordinator?.handleKeyEvent(event, editor: editor) ?? false
        }
        context.coordinator.parentField = field
        return field
    }

    func updateNSView(_ nsView: OmnibarNativeTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.parentField = nsView
        nsView.placeholderString = placeholder

        let desiredDisplayText = inlineCompletion?.displayText ?? text
        if let editor = nsView.currentEditor() as? NSTextView {
            if editor.string != desiredDisplayText {
                context.coordinator.isProgrammaticMutation = true
                editor.string = desiredDisplayText
                nsView.stringValue = desiredDisplayText
                context.coordinator.isProgrammaticMutation = false
            }
        } else if nsView.stringValue != desiredDisplayText {
            nsView.stringValue = desiredDisplayText
        }

        if let window = nsView.window {
            let firstResponder = window.firstResponder
            let isFirstResponder =
                firstResponder === nsView ||
                ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView
            if isFocused, !isFirstResponder {
                window.makeFirstResponder(nsView)
            } else if !isFocused, isFirstResponder {
                window.makeFirstResponder(nil)
            }
        }

        if let editor = nsView.currentEditor() as? NSTextView {
            if let inlineCompletion {
                let currentSelection = editor.selectedRange()
                let desiredSelection = omnibarDesiredSelectionRangeForInlineCompletion(
                    currentSelection: currentSelection,
                    inlineCompletion: inlineCompletion
                )
                if context.coordinator.appliedInlineCompletion != inlineCompletion ||
                    !NSEqualRanges(currentSelection, desiredSelection) {
                    context.coordinator.isProgrammaticMutation = true
                    editor.setSelectedRange(desiredSelection)
                    context.coordinator.isProgrammaticMutation = false
                }
            } else if context.coordinator.appliedInlineCompletion != nil {
                let end = text.utf16.count
                let current = editor.selectedRange()
                if current.length != 0 || current.location != end {
                    context.coordinator.isProgrammaticMutation = true
                    editor.setSelectedRange(NSRange(location: end, length: 0))
                    context.coordinator.isProgrammaticMutation = false
                }
            }
        }
        context.coordinator.appliedInlineCompletion = inlineCompletion
        context.coordinator.attachSelectionObserverIfNeeded()
        context.coordinator.publishSelectionState()
    }

    static func dismantleNSView(_ nsView: OmnibarNativeTextField, coordinator: Coordinator) {
        nsView.onPointerDown = nil
        nsView.onHandleKeyEvent = nil
        nsView.delegate = nil
        coordinator.detachSelectionObserver()
        coordinator.parentField = nil
    }
}

private struct OmnibarSuggestionsView: View {
    let engineName: String
    let items: [OmnibarSuggestion]
    let selectedIndex: Int
    let isLoadingRemoteSuggestions: Bool
    let searchSuggestionsEnabled: Bool
    let onCommit: (OmnibarSuggestion) -> Void
    let onHighlight: (Int) -> Void

    // Keep radii below the smallest rendered heights so corners don't get
    // auto-clamped and visually change as popup height changes.
    private let popupCornerRadius: CGFloat = 16
    private let rowHighlightCornerRadius: CGFloat = 12
    private let singleLineRowHeight: CGFloat = 24
    private let rowSpacing: CGFloat = 1
    private let topInset: CGFloat = 3
    private let bottomInset: CGFloat = 3
    private var horizontalInset: CGFloat { topInset }
    private let maxPopupHeight: CGFloat = 560

    private var totalRowCount: Int {
        max(1, items.count)
    }

    private func rowHeight(for item: OmnibarSuggestion) -> CGFloat {
        return singleLineRowHeight
    }

    private var contentHeight: CGFloat {
        let rowsHeight = items.isEmpty ? singleLineRowHeight : items.reduce(CGFloat(0)) { partial, item in
            partial + rowHeight(for: item)
        }
        let gaps = CGFloat(max(0, totalRowCount - 1))
        return rowsHeight + (gaps * rowSpacing) + topInset + bottomInset
    }

    private var minimumPopupHeight: CGFloat {
        singleLineRowHeight + topInset + bottomInset
    }

    private func snapToDevicePixels(_ value: CGFloat) -> CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    private var popupHeight: CGFloat {
        snapToDevicePixels(min(max(contentHeight, minimumPopupHeight), maxPopupHeight))
    }

    private var isPointerDrivenSelectionEvent: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
             .rightMouseDown, .rightMouseDragged, .rightMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp, .scrollWheel:
            return true
        default:
            return false
        }
    }

    private var shouldScroll: Bool {
        contentHeight > maxPopupHeight
    }

    @ViewBuilder
    private var rowsView: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
            Button {
                #if DEBUG
                dlog("browser.suggestionClick index=\(idx) text=\"\(item.listText)\"")
                #endif
                onCommit(item)
            } label: {
                HStack(spacing: 6) {
                        Text(item.listText)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let badge = item.trailingBadgeText {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.72))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.white.opacity(0.08))
                                )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: rowHeight(for: item),
                        maxHeight: rowHeight(for: item),
                        alignment: .leading
                    )
                    .background(
                        RoundedRectangle(cornerRadius: rowHighlightCornerRadius, style: .continuous)
                            .fill(
                                idx == selectedIndex
                                    ? Color.white.opacity(0.12)
                                    : Color.clear
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("BrowserOmnibarSuggestions.Row.\(idx)")
                .accessibilityValue(
                    idx == selectedIndex
                        ? "selected \(item.listText)"
                        : item.listText
                )
                .onHover { hovering in
                    if hovering, idx != selectedIndex, isPointerDrivenSelectionEvent {
                        onHighlight(idx)
                    }
                }
                .animation(.none, value: selectedIndex)
            }

        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var body: some View {
        Group {
            if shouldScroll {
                ScrollView {
                    rowsView
                }
            } else {
                rowsView
            }
        }
        .frame(height: popupHeight, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if searchSuggestionsEnabled, isLoadingRemoteSuggestions {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 7)
                    .padding(.trailing, 14)
                    .opacity(0.75)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.26),
                                    Color.black.opacity(0.14),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.06),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.45), radius: 20, y: 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityRespondsToUserInteraction(true)
        .accessibilityIdentifier("BrowserOmnibarSuggestions")
        .accessibilityLabel("Address bar suggestions")
    }
}

/// NSViewRepresentable wrapper for WKWebView
struct WebViewRepresentable: NSViewRepresentable {
    let panel: BrowserPanel
    let shouldAttachWebView: Bool
    let shouldFocusWebView: Bool

    final class Coordinator {
        weak var webView: WKWebView?
        var constraints: [NSLayoutConstraint] = []
        var attachRetryWorkItem: DispatchWorkItem?
        var attachRetryCount: Int = 0
        var attachGeneration: Int = 0
    }

    private static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    private static func attachWebView(_ webView: WKWebView, to host: NSView, coordinator: Coordinator) {
        // WebKit can crash if a WKWebView (or an internal first-responder object) stays first responder
        // while being detached/reparented during bonsplit/SwiftUI structural updates.
        if let window = webView.window,
           responderChainContains(window.firstResponder, target: webView) {
            window.makeFirstResponder(nil)
        }

        // Detach from any previous host (bonsplit/SwiftUI may rearrange views).
        webView.removeFromSuperview()
        host.subviews.forEach { $0.removeFromSuperview() }
        host.addSubview(webView)

        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.deactivate(coordinator.constraints)
        coordinator.constraints = [
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ]
        NSLayoutConstraint.activate(coordinator.constraints)

        // Make reparenting resilient: WebKit can occasionally stay visually blank until forced to lay out.
        webView.needsLayout = true
        webView.layoutSubtreeIfNeeded()
        webView.needsDisplay = true
        webView.displayIfNeeded()
    }

    private static func scheduleAttachRetry(_ webView: WKWebView, to host: NSView, coordinator: Coordinator, generation: Int) {
        // Don't schedule multiple overlapping retries.
        guard coordinator.attachRetryWorkItem == nil else { return }

        let work = DispatchWorkItem { [weak host, weak webView] in
            coordinator.attachRetryWorkItem = nil
            guard let host, let webView else { return }
            guard coordinator.attachGeneration == generation else { return }

            // If already attached, we're done.
            if webView.superview === host {
                coordinator.attachRetryCount = 0
                return
            }

            // Wait until the host is actually in a window. SwiftUI can create a new container before it
            // is in a window during bonsplit tree updates; moving the webview too early can be flaky.
            guard host.window != nil else {
                coordinator.attachRetryCount += 1
                // Be generous here: bonsplit structural updates can keep a representable
                // container off-window longer than a few seconds under load.
                if coordinator.attachRetryCount < 400 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scheduleAttachRetry(webView, to: host, coordinator: coordinator, generation: generation)
                    }
                }
                return
            }

            coordinator.attachRetryCount = 0
            attachWebView(webView, to: host, coordinator: coordinator)
        }

        coordinator.attachRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let webView = panel.webView
        context.coordinator.webView = webView

        // Bonsplit keepAllAlive keeps hidden tabs alive (opacity 0). WKWebView is fragile when left
        // in the window hierarchy while hidden and rapidly switching focus between tabs. To reduce
        // WebKit crashes, detach the WKWebView when this surface is not the selected tab in its pane.
        if !shouldAttachWebView {
            context.coordinator.attachRetryWorkItem?.cancel()
            context.coordinator.attachRetryWorkItem = nil
            context.coordinator.attachRetryCount = 0
            context.coordinator.attachGeneration += 1

            // Resign focus if WebKit currently owns first responder.
            if let window = webView.window,
               Self.responderChainContains(window.firstResponder, target: webView) {
                window.makeFirstResponder(nil)
            }

            NSLayoutConstraint.deactivate(context.coordinator.constraints)
            context.coordinator.constraints.removeAll()

            if webView.superview != nil {
                webView.removeFromSuperview()
            }
            nsView.subviews.forEach { $0.removeFromSuperview() }
            return
        }

        if webView.superview !== nsView {
            // Cancel any pending retry; we'll reschedule if needed.
            context.coordinator.attachRetryWorkItem?.cancel()
            context.coordinator.attachRetryWorkItem = nil
            context.coordinator.attachGeneration += 1

            if nsView.window == nil {
                // Avoid attaching to off-window containers; during bonsplit structural updates SwiftUI
                // can create containers that are never inserted into the window.
                Self.scheduleAttachRetry(
                    webView,
                    to: nsView,
                    coordinator: context.coordinator,
                    generation: context.coordinator.attachGeneration
                )
            } else {
                Self.attachWebView(webView, to: nsView, coordinator: context.coordinator)
            }
        } else {
            // Already attached; no need for any pending retry.
            context.coordinator.attachRetryWorkItem?.cancel()
            context.coordinator.attachRetryWorkItem = nil
            context.coordinator.attachRetryCount = 0
            context.coordinator.attachGeneration += 1
        }

        // Focus handling. Avoid fighting the address bar when it is focused.
        guard let window = nsView.window else { return }
        if shouldFocusWebView {
            if panel.shouldSuppressWebViewFocus() {
                return
            }
            if Self.responderChainContains(window.firstResponder, target: webView) {
                return
            }
            window.makeFirstResponder(webView)
        } else {
            if Self.responderChainContains(window.firstResponder, target: webView) {
                window.makeFirstResponder(nil)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attachRetryWorkItem?.cancel()
        coordinator.attachRetryWorkItem = nil
        coordinator.attachRetryCount = 0
        coordinator.attachGeneration += 1

        NSLayoutConstraint.deactivate(coordinator.constraints)
        coordinator.constraints.removeAll()

        guard let webView = coordinator.webView else { return }

        // If we're being torn down while the WKWebView (or one of its subviews) is first responder,
        // resign it before detaching.
        let window = webView.window ?? nsView.window
        if let window, responderChainContains(window.firstResponder, target: webView) {
            window.makeFirstResponder(nil)
        }
        if webView.superview === nsView {
            webView.removeFromSuperview()
        }
    }
}
