import AppKit
import CmuxBrowser
import CmuxFoundation
import CmuxSettings
import SwiftUI

extension OmnibarPaneChrome {
    func publishSuggestionsPresentation() {
        onSuggestionsPresentationChange(suggestionsPresentation)
    }

    func logBrowserFocusState(event: String, detail: String = "") {
#if DEBUG
        var line =
            "browser.focus.trace event=\(event) panel=\(panel.id.uuidString.prefix(5)) " +
            "panelFocused=\(isFocused ? 1 : 0) addrFocused=\(addressBarFocused ? 1 : 0) " +
            "suppressContent=\(panel.shouldSuppressContentFocus() ? 1 : 0)"
        if let pending = panel.pendingAddressBarFocusRequestId {
            line += " pending=\(pending.uuidString.prefix(8))"
        }
        if !detail.isEmpty {
            line += " \(detail)"
        }
        cmuxDebugLog(line)
#endif
    }

    func handleAddressBarFocusedChange(_ focused: Bool) {
#if DEBUG
        logBrowserFocusState(
            event: "addressBarFocus.onChange",
            detail: "next=\(focused ? 1 : 0)"
        )
#endif
        let urlString = panel.preferredURLStringForOmnibar() ?? ""
        if focused {
            let selectionIntent = pendingFocusGainedSelectionIntent
            pendingFocusGainedSelectionIntent = .preserveFieldEditorSelection
            panel.beginSuppressContentFocusForAddressBar()
            NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: panel.id)
            // Only request panel focus if this pane isn't currently focused. When already
            // focused (e.g. Cmd+L), forcing focus can steal first responder back to WebKit.
            if !isFocused {
#if DEBUG
                logBrowserFocusState(event: "addressBarFocus.requestPanelFocus")
#endif
                onRequestPanelFocus()
            }
            let effects = omnibarReduce(
                state: &omnibarState,
                event: .focusGained(currentURLString: urlString, shouldSelectAll: selectionIntent.shouldSelectAll)
            )
            applyOmnibarEffects(effects)
            refreshInlineCompletion()
        } else {
            pendingFocusGainedSelectionIntent = .preserveFieldEditorSelection
            panel.endSuppressContentFocusForAddressBar()
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
        onAddressBarFocusStateChange(focused)
#if DEBUG
        logBrowserFocusState(event: "addressBarFocus.onChange.applied")
#endif
    }

    func handleMoveOmnibarSelection(_ notification: Notification) {
        guard let panelId = notification.object as? UUID, panelId == panel.id else { return }
        guard canHandleOmnibarSuggestionInteraction() else { return }
        guard let delta = notification.userInfo?["delta"] as? Int, delta != 0 else { return }
#if DEBUG
        logBrowserFocusState(event: "addressBarFocus.moveSelection", detail: "delta=\(delta)")
#endif
        let effects = omnibarReduce(state: &omnibarState, event: .moveSelection(delta: delta))
        applyOmnibarEffects(effects)
        refreshInlineCompletion()
    }

    func handleHistoryEntriesChange() {
        guard addressBarFocused else { return }
        refreshSuggestions()
    }

    func handleExternalAddressBarBlur(_ notification: Notification) {
        guard let panelId = notification.object as? UUID,
              panelId == panel.id,
              addressBarFocused else {
            return
        }
#if DEBUG
        logBrowserFocusState(event: "addressBarFocus.externalBlur")
#endif
        setAddressBarFocused(false, reason: "notification.externalBlur")
    }

    func handleCurrentURLChange() {
        let addressWasEmpty = omnibarState.buffer
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        syncURLFromPanel()
        if addressBarFocused,
           !panel.shouldSuppressContentFocus(),
           addressWasEmpty,
           !panel.isContentBlankForOmnibar {
            setAddressBarFocused(false, reason: "panel.currentURL.loaded")
        }
    }

    func canHandleOmnibarSelectionNavigation() -> Bool {
        if addressBarFocused {
            return true
        }
        if AppDelegate.shared?.focusedBrowserAddressBarPanelId() == panel.id {
            return true
        }
        let fieldWindow = panel.omnibarHostWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let field = browserOmnibarField(panelId: panel.id, in: fieldWindow),
           field.currentEditor() != nil {
            return true
        }
        return false
    }

    func canHandleOmnibarSuggestionInteraction() -> Bool {
        canHandleOmnibarSelectionNavigation() && hasActionableOmnibarSuggestions
    }

    func setAddressBarFocused(
        _ focused: Bool,
        reason: String,
        focusGainedSelectionIntent: BrowserAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
    ) {
#if DEBUG
        if addressBarFocused == focused {
            logBrowserFocusState(
                event: "addressBarFocus.write.noop",
                detail: "reason=\(reason) value=\(focused ? 1 : 0)"
            )
        } else {
            logBrowserFocusState(
                event: "addressBarFocus.write",
                detail: "reason=\(reason) old=\(addressBarFocused ? 1 : 0) new=\(focused ? 1 : 0)"
            )
        }
#endif
        if focused, !addressBarFocused {
            pendingFocusGainedSelectionIntent = focusGainedSelectionIntent
        } else if !focused {
            pendingFocusGainedSelectionIntent = .preserveFieldEditorSelection
        }
        addressBarFocused = focused
        if focused {
            panel.noteAddressBarFocused()
        }
    }

    func syncURLFromPanel() {
        let urlString = panel.preferredURLStringForOmnibar() ?? ""
        let effects = omnibarReduce(state: &omnibarState, event: .panelURLChanged(currentURLString: urlString))
        applyOmnibarEffects(effects)
    }

    func isCommandPaletteVisibleForPanelWindow() -> Bool {
        guard let app = AppDelegate.shared else { return false }

        if let window = panel.omnibarHostWindow, app.isCommandPaletteVisible(for: window) {
            return true
        }

        if let manager = app.tabManagerFor(tabId: panel.workspaceId),
           let windowId = app.windowId(for: manager),
           let window = app.mainWindow(for: windowId),
           app.isCommandPaletteVisible(for: window) {
            return true
        }

        if let keyWindow = NSApp.keyWindow, app.isCommandPaletteVisible(for: keyWindow) {
            return true
        }
        if let mainWindow = NSApp.mainWindow, app.isCommandPaletteVisible(for: mainWindow) {
            return true
        }
        return false
    }

    func commandPaletteVisibilityNotificationMatchesPanelWindow(_ notification: Notification) -> Bool {
        if let notificationWindow = notification.object as? NSWindow,
           panel.omnibarHostWindow === notificationWindow {
            return true
        }

        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId),
              let panelWindowId = app.windowId(for: manager) else {
            return false
        }

        if let notificationWindowId = notification.userInfo?["windowId"] as? UUID {
            return notificationWindowId == panelWindowId
        }

        if let notificationWindow = notification.object as? NSWindow,
           let panelWindow = app.mainWindow(for: panelWindowId) {
            return notificationWindow === panelWindow
        }
        return false
    }

    func applyPendingAddressBarFocusRequestIfNeeded() {
        guard let requestId = panel.pendingAddressBarFocusRequestId else {
            return
        }
        guard panel.isOmnibarVisible else {
            lastHandledAddressBarFocusRequestId = requestId
            panel.acknowledgeAddressBarFocusRequest(requestId)
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply.skip",
                detail: "reason=chrome_hidden request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return
        }
        guard !isCommandPaletteVisibleForPanelWindow() else {
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply.skip",
                detail: "reason=command_palette_visible request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return
        }
        guard lastHandledAddressBarFocusRequestId != requestId else {
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply.skip",
                detail: "reason=already_handled request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return
        }
        lastHandledAddressBarFocusRequestId = requestId
        let selectionIntent = panel.pendingAddressBarFocusSelectionIntent
        panel.beginSuppressContentFocusForAddressBar()
#if DEBUG
        logBrowserFocusState(
            event: "addressBarFocus.request.apply",
            detail: "request=\(requestId.uuidString.prefix(8)) selection=\(String(describing: selectionIntent))"
        )
#endif

        if addressBarFocused {
            // Re-run explicit selection behavior only for requests that own it
            // (Cmd+L), without replacing a caret from focus restoration.
            let effects = omnibarReduce(
                state: &omnibarState,
                event: .focusReasserted(
                    shouldSelectAll: browserOmnibarShouldSelectAllOnFocusReassertion(
                        selectionIntent: selectionIntent
                    )
                )
            )
            applyOmnibarEffects(effects)
            refreshInlineCompletion()
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply",
                detail: "request=\(requestId.uuidString.prefix(8)) mode=refresh"
            )
#endif
        } else {
            setAddressBarFocused(
                true,
                reason: "request.apply",
                focusGainedSelectionIntent: selectionIntent
            )
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply",
                detail: "request=\(requestId.uuidString.prefix(8)) mode=set_focused"
            )
#endif
        }

        panel.acknowledgeAddressBarFocusRequest(requestId)
#if DEBUG
        logBrowserFocusState(
            event: "addressBarFocus.request.ack",
            detail: "request=\(requestId.uuidString.prefix(8))"
        )
#endif
    }

    func autoFocusOmnibarIfBlank() {
        guard panel.isOmnibarVisible else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=omnibar_hidden")
#endif
            return
        }
        guard isFocused else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=panel_not_focused")
#endif
            return
        }
        guard !addressBarFocused else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=already_focused")
#endif
            return
        }
        guard !isCommandPaletteVisibleForPanelWindow() else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=command_palette_visible")
#endif
            return
        }
        // If a test/automation explicitly focused WebKit, don't steal focus back.
        guard !panel.shouldSuppressOmnibarAutofocus() else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=autofocus_suppressed")
#endif
            return
        }
        // If a real navigation is underway (e.g. open_browser https://...), don't steal focus.
        guard !panel.isContentNavigationInFlight else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=webview_loading")
#endif
            return
        }
        guard panel.isContentBlankForOmnibar else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=webview_not_blank")
#endif
            return
        }
        setAddressBarFocused(true, reason: "autoFocus.blank")
#if DEBUG
        logBrowserFocusState(event: "addressBarFocus.autoFocus.apply")
#endif
    }

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

}

