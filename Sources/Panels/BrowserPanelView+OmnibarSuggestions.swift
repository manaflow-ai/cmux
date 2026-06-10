import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Omnibar Suggestions & Effects
extension BrowserPanelView {
    func handleOmnibarTap() {
#if DEBUG
        logBrowserFocusState(event: "addressBar.tap")
#endif
        let wasAddressBarFocused = addressBarFocused
        let shouldRequestPanelFocus = !isFocused
        if !wasAddressBarFocused {
            // Mark focused before pane selection converges so WebKit focus is not
            // briefly re-acquired during `focusPane`.
            setAddressBarFocused(true, reason: "omnibar.tap")
        }
        if shouldRequestPanelFocus && wasAddressBarFocused {
            onRequestPanelFocus()
        }
    }

    func hideSuggestions() {
        cancelPendingOmnibarSuggestionWork()
        let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated([]))
        applyOmnibarEffects(effects)
        inlineCompletion = nil
    }

    func startOmnibarSuggestionRefreshConsumer() {
        guard omnibarSuggestionRefreshConsumerTask == nil else { return }
        let scheduler = omnibarSuggestionRefreshScheduler
        omnibarSuggestionRefreshConsumerTask = Task { @MainActor in
            for await generation in scheduler.refreshStream {
                guard scheduler.shouldProcessRefresh(generation) else { continue }
                refreshSuggestions()
            }
        }
    }

    func stopOmnibarSuggestionRefreshConsumer() {
        omnibarSuggestionRefreshConsumerTask?.cancel()
        omnibarSuggestionRefreshConsumerTask = nil
    }

    func cancelPendingOmnibarSuggestionWork() {
        omnibarSuggestionRefreshScheduler.cancelPendingRefresh()
        suggestionTask?.cancel()
        suggestionTask = nil
        isLoadingRemoteSuggestions = false
    }

    func commitSelectedSuggestion() {
        let idx = omnibarState.selectedSuggestionIndex
        guard idx >= 0, idx < omnibarState.suggestions.count else { return }
        commitSuggestion(omnibarState.suggestions[idx])
    }

    func commitSuggestion(_ suggestion: OmnibarSuggestion) {
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
        setAddressBarFocused(false, reason: "suggestion.commit")
    }

    func handleOmnibarEscape() {
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

    func handleOmnibarSelectionChange(range: NSRange, hasMarkedText: Bool) {
        let didBeginComposition = !omnibarHasMarkedText && hasMarkedText
        omnibarSelectionRange = range
        omnibarHasMarkedText = hasMarkedText
        if didBeginComposition {
            hideSuggestions()
        } else {
            // Do not refresh suggestions from selection-state publication. On
            // composition end, the committed buffer change immediately follows.
            refreshInlineCompletion()
        }
    }

    func acceptInlineCompletion() {
        guard let completion = inlineCompletion else { return }
        let effects = omnibarReduce(state: &omnibarState, event: .bufferChanged(completion.displayText))
        applyOmnibarEffects(effects)
        inlineCompletion = nil
    }

    func handleInlineBackspace() {
        guard let completion = inlineCompletion else { return }
        let prefix = completion.typedText
        guard !prefix.isEmpty else { return }
        let updated = String(prefix.dropLast())
        let effects = omnibarReduce(state: &omnibarState, event: .bufferChanged(updated))
        applyOmnibarEffects(effects)
        omnibarSelectionRange = NSRange(location: updated.utf16.count, length: 0)
        if !effects.shouldClearInlineCompletion {
            refreshInlineCompletion()
        }
    }

    func handleInlineClearTypedPrefix() {
        guard inlineCompletion != nil else { return }
        // Modified Backspace dismisses the current inline suggestion instead of
        // refetching suggestions for the shorter prefix.
        _ = omnibarReduce(state: &omnibarState, event: .bufferChanged(""))
        omnibarSelectionRange = NSRange(location: 0, length: 0)
        hideSuggestions()
    }

    func handleInlineDeleteWordBackward() {
        guard let completion = inlineCompletion else { return }
        let updated = omnibarPrefixAfterDeletingTrailingWord(from: completion.typedText)
        // Modified Backspace dismisses the current inline suggestion instead of
        // refetching suggestions for the shorter prefix.
        _ = omnibarReduce(state: &omnibarState, event: .bufferChanged(updated))
        omnibarSelectionRange = NSRange(location: updated.utf16.count, length: 0)
        hideSuggestions()
    }

    func deleteSelectedSuggestionIfPossible() {
        let idx = omnibarState.selectedSuggestionIndex
        guard idx >= 0, idx < omnibarState.suggestions.count else { return }

        let target = omnibarState.suggestions[idx]
        guard case .history(let url, _) = target.kind else { return }
        guard panel.historyStore.removeHistoryEntry(urlString: url) else { return }
        refreshSuggestions()
    }

    func refreshInlineCompletion() {
        inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: omnibarState.buffer,
            suggestions: omnibarState.suggestions,
            isFocused: addressBarFocused,
            selectionRange: omnibarSelectionRange,
            hasMarkedText: omnibarHasMarkedText
        )
    }

    func refreshSuggestions() {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            let trimmedQuery = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            CmuxTypingTiming.logDuration(
                path: "browser.omnibar.refreshSuggestions",
                startedAt: typingTimingStart,
                extra: "focused=\(addressBarFocused ? 1 : 0) queryLen=\(trimmedQuery.utf8.count) suggestionCount=\(omnibarState.suggestions.count)"
            )
        }
#endif
        suggestionTask?.cancel()
        suggestionTask = nil
        isLoadingRemoteSuggestions = false

        guard addressBarFocused, !omnibarHasMarkedText else {
#if DEBUG
            cmuxDebugLog(
                "browser.omnibar.suggestions refresh=skip " +
                "panel=\(panel.id.uuidString.prefix(5)) " +
                "focused=\(addressBarFocused ? 1 : 0) marked=\(omnibarHasMarkedText ? 1 : 0) " +
                "bufferLen=\(omnibarState.buffer.utf8.count)"
            )
#endif
            let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated([]))
            applyOmnibarEffects(effects)
            return
        }

        let query = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let historyEntries: [BrowserHistoryStore.Entry] = {
            if query.isEmpty {
                return panel.historyStore.recentSuggestions(limit: 12)
            }
            return panel.historyStore.suggestions(for: query, limit: 12)
        }()
        let openTabMatches = query.isEmpty ? [] : matchingOpenTabSuggestions(for: query, limit: 12)
        let isSingleCharacterQuery = omnibarSingleCharacterQuery(for: query) != nil
        let remoteSuggestionsEngine = searchConfiguration.remoteSuggestionsEngine
        let allowsRemoteSuggestions = remoteSuggestionsEnabled && remoteSuggestionsEngine != nil
        if !allowsRemoteSuggestions {
            latestRemoteSuggestionQuery = ""
            latestRemoteSuggestions = []
        }
        let staleRemote: [String]
        if query.isEmpty || isSingleCharacterQuery {
            staleRemote = []
        } else {
            staleRemote = staleRemoteSuggestionsForDisplay(
                query: query,
                allowsRemoteSuggestions: allowsRemoteSuggestions
            )
        }
        let resolvedURL = query.isEmpty ? nil : panel.resolveNavigableURL(from: query)
        let items = buildOmnibarSuggestions(
            query: query,
            engineName: searchConfiguration.displayName,
            historyEntries: historyEntries,
            openTabMatches: openTabMatches,
            remoteQueries: staleRemote,
            resolvedURL: resolvedURL,
            limit: 8
        )
        let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated(items))
        applyOmnibarEffects(effects)
        refreshInlineCompletion()
#if DEBUG
        cmuxDebugLog(
            "browser.omnibar.suggestions refresh=local " +
            "panel=\(panel.id.uuidString.prefix(5)) queryLen=\(query.utf8.count) " +
            "items=\(items.count) history=\(historyEntries.count) openTabs=\(openTabMatches.count) " +
            "staleRemote=\(staleRemote.count) frameWidth=\(String(format: "%.1f", omnibarPillFrame.width)) " +
            "portal=\(shouldRenderOmnibarSuggestionsInPortal ? 1 : 0)"
        )
#endif

        guard !query.isEmpty else { return }

        if !isSingleCharacterQuery, let forcedRemote = forcedRemoteSuggestionsForUITest() {
            latestRemoteSuggestionQuery = query
            latestRemoteSuggestions = forcedRemote
            let merged = buildOmnibarSuggestions(
                query: query,
                engineName: searchConfiguration.displayName,
                historyEntries: historyEntries,
                openTabMatches: openTabMatches,
                remoteQueries: forcedRemote,
                resolvedURL: resolvedURL,
                limit: 8
            )
            let forcedEffects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated(merged))
            applyOmnibarEffects(forcedEffects)
            refreshInlineCompletion()
#if DEBUG
            cmuxDebugLog(
                "browser.omnibar.suggestions refresh=forcedRemote " +
                "panel=\(panel.id.uuidString.prefix(5)) queryLen=\(query.utf8.count) items=\(merged.count)"
            )
#endif
            return
        }

        guard remoteSuggestionsEnabled else { return }
        guard !isSingleCharacterQuery else { return }
        guard omnibarInputIntent(for: query) != .urlLike else { return }

        // Keep current remote rows visible while fetching fresh predictions.
        guard let engine = remoteSuggestionsEngine else { return }
        isLoadingRemoteSuggestions = true
        suggestionTask = Task {
            let remote = await BrowserSearchSuggestionService.shared.suggestions(engine: engine, query: query)
            if Task.isCancelled { return }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard addressBarFocused, !omnibarHasMarkedText else { return }
                let current = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard current == query else { return }
                latestRemoteSuggestionQuery = query
                latestRemoteSuggestions = remote
                let merged = buildOmnibarSuggestions(
                    query: query,
                    engineName: searchConfiguration.displayName,
                    historyEntries: panel.historyStore.suggestions(for: query, limit: 12),
                    openTabMatches: matchingOpenTabSuggestions(for: query, limit: 12),
                    remoteQueries: remote,
                    resolvedURL: panel.resolveNavigableURL(from: query),
                    limit: 8
                )
                let effects = omnibarReduce(state: &omnibarState, event: .suggestionsUpdated(merged))
                applyOmnibarEffects(effects)
                refreshInlineCompletion()
                isLoadingRemoteSuggestions = false
#if DEBUG
                cmuxDebugLog(
                    "browser.omnibar.suggestions refresh=remote " +
                    "panel=\(panel.id.uuidString.prefix(5)) queryLen=\(query.utf8.count) " +
                    "remote=\(remote.count) items=\(merged.count)"
                )
#endif
            }
        }
    }

    private func staleRemoteSuggestionsForDisplay(
        query: String,
        allowsRemoteSuggestions: Bool = true
    ) -> [String] {
        staleOmnibarRemoteSuggestionsForDisplay(
            query: query,
            previousRemoteQuery: latestRemoteSuggestionQuery,
            previousRemoteSuggestions: latestRemoteSuggestions,
            allowsRemoteSuggestions: allowsRemoteSuggestions
        )
    }

    private func matchingOpenTabSuggestions(for query: String, limit: Int) -> [OmnibarOpenTabMatch] {
        guard !query.isEmpty, limit > 0 else { return [] }
        let singleCharacterQuery = omnibarSingleCharacterQuery(for: query)
        let includeCurrentPanelForSingleCharacterQuery = singleCharacterQuery != nil
        let currentPanelSnapshot = BrowserOpenTabSuggestionSnapshot(
            workspaceId: panel.workspaceId,
            panelId: panel.id,
            url: panel.preferredURLStringForOmnibar(),
            title: panel.pageTitle
        )
        let tabManager = AppDelegate.shared?.tabManagerFor(tabId: panel.workspaceId) ?? AppDelegate.shared?.tabManager
        return tabManager?.matchingOpenBrowserTabSuggestions(
            for: query,
            currentWorkspaceId: panel.workspaceId,
            currentPanelId: panel.id,
            currentPanelSnapshot: currentPanelSnapshot,
            includeCurrentPanelForSingleCharacterQuery: includeCurrentPanelForSingleCharacterQuery,
            limit: limit
        ) ?? []
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

    func applyOmnibarEffects(_ effects: OmnibarEffects) {
        if effects.shouldCancelPendingSuggestionRefresh {
            cancelPendingOmnibarSuggestionWork()
        }
        if effects.shouldClearInlineCompletion {
            inlineCompletion = nil
        }
        if effects.shouldRefreshSuggestions {
            omnibarSuggestionRefreshScheduler.scheduleRefresh()
        }
        if effects.shouldSelectAll {
            omnibarSelectAllRequestId &+= 1
        }
        if effects.shouldBlurToWebView {
            hideSuggestions()
            // This transition is stateful: drop omnibar focus suppression before
            // attempting responder handoff so WKWebView can actually become first responder.
            panel.endSuppressWebViewFocusForAddressBar()
            syncWebViewResponderPolicyWithViewState(reason: "effects.blurToWebView.preHandoff")
            setAddressBarFocused(false, reason: "effects.blurToWebView")
            DispatchQueue.main.async {
                guard let window = panel.webView.window,
                      !panel.webView.isHiddenOrHasHiddenAncestor else { return }
                guard shouldApplyAddressBarExitFallback(in: window) else {
#if DEBUG
                    cmuxDebugLog(
                        "browser.focus.addressBar.exit.handoff panel=\(panel.id.uuidString.prefix(5)) " +
                        "result=skip_not_focused"
                    )
#endif
                    NotificationCenter.default.post(name: .browserDidExitAddressBar, object: panel.id)
                    return
                }
                syncWebViewResponderPolicyWithViewState(reason: "effects.blurToWebView.handoff")
                panel.clearWebViewFocusSuppression()
                let focusedWebView = window.makeFirstResponder(panel.webView)
                if focusedWebView {
                    panel.noteWebViewFocused()
                }
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.addressBar.exit.handoff panel=\(panel.id.uuidString.prefix(5)) " +
                    "focusedWebView=\(focusedWebView ? 1 : 0)"
                )
#endif
                panel.restoreAddressBarPageFocusIfNeeded { restored in
                    guard shouldApplyAddressBarExitFallback(in: window) else {
#if DEBUG
                        cmuxDebugLog(
                            "browser.focus.addressBar.exit.handoff panel=\(panel.id.uuidString.prefix(5)) " +
                            "result=skip_stale_restore restored=\(restored ? 1 : 0)"
                        )
#endif
                        NotificationCenter.default.post(name: .browserDidExitAddressBar, object: panel.id)
                        return
                    }
                    var hasWebViewResponder =
                        browserFocusResponderChainContains(window.firstResponder, target: panel.webView)
                    if !hasWebViewResponder {
                        let fallbackFocusedWebView = window.makeFirstResponder(panel.webView)
                        hasWebViewResponder = fallbackFocusedWebView
#if DEBUG
                        cmuxDebugLog(
                            "browser.focus.addressBar.exit.handoff panel=\(panel.id.uuidString.prefix(5)) " +
                            "fallbackFocusedWebView=\(fallbackFocusedWebView ? 1 : 0) " +
                            "restored=\(restored ? 1 : 0)"
                        )
#endif
                    }
                    if hasWebViewResponder {
                        panel.noteWebViewFocused()
                    }
                    NotificationCenter.default.post(name: .browserDidExitAddressBar, object: panel.id)
                }
            }
        }
    }
}
