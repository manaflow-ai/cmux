import SwiftUI
import WebKit
import AppKit

/// View for rendering a browser panel with address bar
struct BrowserPanelView: View {
    @ObservedObject var panel: BrowserPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void
    @State private var omnibarState = OmnibarState()
    @FocusState private var addressBarFocused: Bool
    @AppStorage(BrowserSearchSettings.searchEngineKey) private var searchEngineRaw = BrowserSearchSettings.defaultSearchEngine.rawValue
    @AppStorage(BrowserSearchSettings.searchSuggestionsEnabledKey) private var searchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
    @State private var suggestionTask: Task<Void, Never>?
    @State private var isLoadingRemoteSuggestions: Bool = false
    @State private var suppressNextFocusLostRevert: Bool = false
    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashFadeWorkItem: DispatchWorkItem?

    private var searchEngine: BrowserSearchEngine {
        BrowserSearchEngine(rawValue: searchEngineRaw) ?? BrowserSearchSettings.defaultSearchEngine
    }

    private var remoteSuggestionsEnabled: Bool {
        // Keep UI tests deterministic by disabling network suggestions when requested.
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] == "1" {
            return false
        }
        return searchSuggestionsEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            // Address bar
            HStack(spacing: 8) {
                let navButtonSize: CGFloat = 22

                // Back button
                Button(action: { panel.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: navButtonSize, height: navButtonSize, alignment: .center)
                }
                .buttonStyle(.plain)
                .frame(width: navButtonSize, height: navButtonSize, alignment: .center)
                .disabled(!panel.canGoBack)
                .opacity(panel.canGoBack ? 1.0 : 0.4)
                .help("Go Back")

                // Forward button
                Button(action: { panel.goForward() }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: navButtonSize, height: navButtonSize, alignment: .center)
                }
                .buttonStyle(.plain)
                .frame(width: navButtonSize, height: navButtonSize, alignment: .center)
                .disabled(!panel.canGoForward)
                .opacity(panel.canGoForward ? 1.0 : 0.4)
                .help("Go Forward")

                // Reload/Stop button
                Button(action: {
                    if panel.isLoading {
                        panel.stopLoading()
                    } else {
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

                // URL TextField
                HStack(spacing: 4) {
                    if panel.currentURL?.scheme == "https" {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    TextField(
                        "Search or enter URL",
                        text: Binding(
                            get: { omnibarState.buffer },
                            set: { newValue in
                                let effects = omnibarReduce(state: &omnibarState, event: .bufferChanged(newValue))
                                applyOmnibarEffects(effects)
                            }
                        )
                    )
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($addressBarFocused)
                        .accessibilityIdentifier("BrowserOmnibarTextField")
                        .simultaneousGesture(TapGesture().onEnded {
                            handleOmnibarTap()
                        })
                        .onExitCommand {
                            // Chrome-style escape:
                            // - If editing / dropdown is open: revert to current URL, close dropdown, select all.
                            // - Otherwise: blur to the web view.
                            guard addressBarFocused else { return }
                            let effects = omnibarReduce(state: &omnibarState, event: .escape)
                            applyOmnibarEffects(effects)
                        }
                        .onSubmit {
                            if addressBarFocused, !omnibarState.suggestions.isEmpty {
                                commitSelectedSuggestion()
                            } else {
                                panel.navigateSmart(omnibarState.buffer)
                                hideSuggestions()
                                suppressNextFocusLostRevert = true
                                addressBarFocused = false
                            }
                        }
                        // XCUITest (and some SwiftUI/AppKit focus edge cases) can fail to trigger `onSubmit`
                        // reliably for TextField on macOS. Handle Return explicitly so Enter commits the
                        // selected suggestion (or navigates) like Chrome.
                        .backport.onKeyPress(.return) { _ in
                            guard addressBarFocused else { return .ignored }
                            if !omnibarState.suggestions.isEmpty {
                                commitSelectedSuggestion()
                            } else {
                                panel.navigateSmart(omnibarState.buffer)
                                hideSuggestions()
                                suppressNextFocusLostRevert = true
                                addressBarFocused = false
                            }
                            return .handled
                        }
                        .backport.onKeyPress(.downArrow) { _ in
                            guard addressBarFocused, !omnibarState.suggestions.isEmpty else { return .ignored }
                            let effects = omnibarReduce(state: &omnibarState, event: .moveSelection(delta: +1))
                            applyOmnibarEffects(effects)
                            return .handled
                        }
                        .backport.onKeyPress(.upArrow) { _ in
                            guard addressBarFocused, !omnibarState.suggestions.isEmpty else { return .ignored }
                            let effects = omnibarReduce(state: &omnibarState, event: .moveSelection(delta: -1))
                            applyOmnibarEffects(effects)
                            return .handled
                        }
                        .backport.onKeyPress("n") { modifiers in
                            // Emacs-style navigation: Ctrl+N / Ctrl+P.
                            guard modifiers.contains(.control) else { return .ignored }
                            guard addressBarFocused, !omnibarState.suggestions.isEmpty else { return .ignored }
                            let effects = omnibarReduce(state: &omnibarState, event: .moveSelection(delta: +1))
                            applyOmnibarEffects(effects)
                            return .handled
                        }
                        .backport.onKeyPress("p") { modifiers in
                            guard modifiers.contains(.control) else { return .ignored }
                            guard addressBarFocused, !omnibarState.suggestions.isEmpty else { return .ignored }
                            let effects = omnibarReduce(state: &omnibarState, event: .moveSelection(delta: -1))
                            applyOmnibarEffects(effects)
                            return .handled
                        }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(addressBarFocused ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("BrowserOmnibarPill")
                .accessibilityLabel("Browser omnibar")
                .overlay(alignment: .topLeading) {
                    GeometryReader { geo in
                        if addressBarFocused, !omnibarState.suggestions.isEmpty {
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
                            .frame(width: geo.size.width)
                            .offset(y: geo.size.height + 6)
                            .zIndex(1000)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))

            // Web view
            WebViewRepresentable(
                panel: panel,
                shouldAttachWebView: isVisibleInUI,
                shouldFocusWebView: isFocused && !addressBarFocused
            )
                // Keep the representable identity stable across bonsplit structural updates.
                // This reduces WKWebView reparenting churn (and the associated WebKit crashes).
                .id(panel.id)
                .contextMenu {
                    Button("Open Developer Tools") {
                        openDevTools()
                    }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: Color.accentColor.opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(6)
                .allowsHitTesting(false)
        }
        .onAppear {
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
            if addressBarFocused, addressWasEmpty, !isWebViewBlank() {
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
            let urlString = panel.currentURL?.absoluteString ?? ""
            if focused {
                NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: panel.id)
                // Only request panel focus if this pane isn't currently focused. When already
                // focused (e.g. Cmd+L), forcing focus can steal first responder back to WebKit.
                if !isFocused {
                    onRequestPanelFocus()
                }
                let effects = omnibarReduce(state: &omnibarState, event: .focusGained(currentURLString: urlString))
                applyOmnibarEffects(effects)
            } else {
                NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panel.id)
                if suppressNextFocusLostRevert {
                    suppressNextFocusLostRevert = false
                    let effects = omnibarReduce(state: &omnibarState, event: .focusLostPreserveBuffer(currentURLString: urlString))
                    applyOmnibarEffects(effects)
                } else {
                    let effects = omnibarReduce(state: &omnibarState, event: .focusLostRevertBuffer(currentURLString: urlString))
                    applyOmnibarEffects(effects)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserFocusAddressBar)) { notification in
            guard let panelId = notification.object as? UUID, panelId == panel.id else { return }
            addressBarFocused = true
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
        let urlString = panel.currentURL?.absoluteString ?? ""
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
        panel.navigateSmart(suggestion.completion)
        hideSuggestions()
        suppressNextFocusLostRevert = true
        addressBarFocused = false
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
        guard !query.isEmpty else {
            let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated([]))
            applyOmnibarEffects(effects)
            return
        }

        var items: [OmnibarSuggestion] = []
        var seen = Set<String>()

        func insert(_ item: OmnibarSuggestion) {
            let key = item.completion.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            items.append(item)
        }

        insert(.search(engineName: searchEngine.displayName, query: query))

        let history = BrowserHistoryStore.shared.suggestions(for: query, limit: 8)
        for entry in history {
            insert(.history(entry))
        }

        let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated(items))
        applyOmnibarEffects(effects)

        guard searchSuggestionsEnabled else { return }
        guard remoteSuggestionsEnabled else { return }

        // Debounced remote suggestions (Google/DDG/Bing).
        let engine = searchEngine
        isLoadingRemoteSuggestions = true
        suggestionTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }

            let remote = await BrowserSearchSuggestionService.shared.suggestions(engine: engine, query: query)
            if Task.isCancelled { return }

            await MainActor.run {
                guard addressBarFocused else { return }
                let current = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard current == query else { return }

                var merged = omnibarState.suggestions
                var mergedSeen = Set(merged.map { $0.completion.lowercased() })
                var insertionIndex = min(1, merged.count) // right below the "Search …" row
                for s in remote.prefix(8) {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let key = trimmed.lowercased()
                    guard !mergedSeen.contains(key) else { continue }
                    mergedSeen.insert(key)
                    merged.insert(.remoteSearchSuggestion(trimmed), at: insertionIndex)
                    insertionIndex += 1
                }
                let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated(merged))
                applyOmnibarEffects(effects)
                isLoadingRemoteSuggestions = false
            }
        }
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
                window.makeFirstResponder(panel.webView)
                NotificationCenter.default.post(name: .browserDidExitAddressBar, object: panel.id)
            }
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
        effects.shouldSelectAll = true

    case .focusLostRevertBuffer(let url):
        state.isFocused = false
        state.currentURLString = url
        state.buffer = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0

    case .focusLostPreserveBuffer(let url):
        state.isFocused = false
        state.currentURLString = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0

    case .panelURLChanged(let url):
        state.currentURLString = url
        if !state.isUserEditing {
            state.buffer = url
            state.suggestions = []
            state.selectedSuggestionIndex = 0
        }

    case .bufferChanged(let newValue):
        state.buffer = newValue
        if state.isFocused {
            state.isUserEditing = (newValue != state.currentURLString)
            state.selectedSuggestionIndex = 0
            effects.shouldRefreshSuggestions = true
        }

    case .suggestionsUpdated(let items):
        state.suggestions = items
        if items.isEmpty {
            state.selectedSuggestionIndex = 0
        } else {
            state.selectedSuggestionIndex = min(max(0, state.selectedSuggestionIndex), items.count - 1)
        }

    case .moveSelection(let delta):
        guard !state.suggestions.isEmpty else { break }
        state.selectedSuggestionIndex = min(
            max(0, state.selectedSuggestionIndex + delta),
            state.suggestions.count - 1
        )

    case .highlightIndex(let idx):
        guard !state.suggestions.isEmpty else { break }
        state.selectedSuggestionIndex = min(max(0, idx), state.suggestions.count - 1)

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
        case history(url: String, title: String?)
        case remote(query: String)
    }

    let id: UUID = UUID()
    let kind: Kind

    var completion: String {
        switch kind {
        case .search(_, let q): return q
        case .history(let url, _): return url
        case .remote(let q): return q
        }
    }

    var iconName: String {
        switch kind {
        case .search: return "magnifyingglass"
        case .history: return "clock"
        case .remote: return "magnifyingglass"
        }
    }

    var primaryText: String {
        switch kind {
        case .search(let engineName, let q):
            return "Search \(engineName) for \"\(q)\""
        case .history(let url, let title):
            return (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? (title ?? url) : url
        case .remote(let q):
            return q
        }
    }

    var secondaryText: String? {
        switch kind {
        case .history(let url, let title):
            let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedTitle.isEmpty ? nil : url
        default:
            return nil
        }
    }

    static func history(_ entry: BrowserHistoryStore.Entry) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .history(url: entry.url, title: entry.title))
    }

    static func search(engineName: String, query: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .search(engineName: engineName, query: query))
    }

    static func remoteSearchSuggestion(_ query: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .remote(query: query))
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

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    Button {
                        onCommit(item)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.iconName)
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.primaryText)
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if let secondary = item.secondaryText {
                                    Text(secondary)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            idx == selectedIndex
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("BrowserOmnibarSuggestions.Row.\(idx)")
                    .accessibilityValue(idx == selectedIndex ? "selected" : "")
                    .onHover { hovering in
                        if hovering {
                            onHighlight(idx)
                        }
                    }

                    if idx != items.count - 1 {
                        Divider()
                            .opacity(0.5)
                    }
                }

                if searchSuggestionsEnabled, isLoadingRemoteSuggestions {
                    Divider()
                        .opacity(0.5)
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16)
                        Text("Loading suggestions…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxHeight: 240)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
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
