import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Panel Lifecycle & Change Handlers
extension BrowserPanelView {
    func handleBrowserPanelAppear() {
        // One-time setup must not re-run on every commit; `.onAppear` can re-fire
        // repeatedly for a portal-hosted pane (issue #5303). Everything below the
        // setup call is idempotent and cheap, and genuine state transitions are
        // already handled by the dedicated `.onChange` observers on `body`, so
        // re-running this per appear is harmless once the heavy/one-time work is
        // gated out.
        performInitialBrowserPanelSetupIfNeeded()
        startOmnibarSuggestionRefreshConsumer()
        refreshBrowserChromeStyle()
        panel.noteWebViewVisibility(
            isVisibleInUI && isCurrentPaneOwner,
            reason: "view.onAppear"
        )
        panel.refreshAppearanceDrivenColors()
        panel.setBrowserThemeMode(browserThemeMode)
        applyPendingAddressBarFocusRequestIfNeeded()
        syncURLFromPanel()
        // If the browser surface is focused but has no URL loaded yet, auto-focus the omnibar.
        autoFocusOmnibarIfBlank()
        syncWebViewResponderPolicyWithViewState(reason: "onAppear")
        panel.historyStore.loadIfNeeded()
#if DEBUG
        logBrowserFocusState(event: "view.onAppear")
#endif
        focusModeShortcutHintMonitor.start()
    }

    /// Runs the view-state initialization that should happen on first appearance,
    /// independent of how many times SwiftUI fires `.onAppear` for the same view
    /// instance.
    ///
    /// `.onAppear` is not a reliable once-or-on-transition signal for a portal-hosted
    /// browser pane — it can re-fire on every CoreAnimation commit (issue #5303).
    /// Default registration and settings normalization are app-once work and live in
    /// ``BrowserPanel/bootstrapBrowserDefaultsIfNeeded()`` (run from the model
    /// init), not here. This method only seeds view-local state: the initial
    /// empty-state import list, which `handleCurrentURLChange` refreshes on subsequent
    /// new-tab navigations.
    private func performInitialBrowserPanelSetupIfNeeded() {
        guard !didCompleteInitialBrowserPanelSetup else { return }
        didCompleteInitialBrowserPanelSetup = true
        refreshEmptyStateImportBrowsers()
    }

    func handleOmnibarVisibilityChange(_ isVisible: Bool) {
        if !isVisible {
            hideSuggestions()
            setAddressBarFocused(false, reason: "omnibarVisibility.hidden")
            addressBarHeight = 0
        } else {
            applyPendingAddressBarFocusRequestIfNeeded()
        }
        syncWebViewResponderPolicyWithViewState(reason: "omnibarVisibilityChanged")
    }

    func handleBrowserPanelDisappear() {
        stopOmnibarSuggestionRefreshConsumer()
        cancelPendingOmnibarSuggestionWork()
        focusModeShortcutHintMonitor.stop()
        screenshotPageCopiedTimer?.invalidate()
        screenshotPageCopiedTimer = nil
        screenshotPageCopied = false
    }

    func handleBrowserWebViewClickIntent(_ notification: Notification) {
        guard let webView = notification.object as? CmuxWebView,
              webView === panel.webView else {
            return
        }
#if DEBUG
        cmuxDebugLog(
            "browser.focus.clickIntent panel=\(panel.id.uuidString.prefix(5)) " +
            "isFocused=\(isFocused ? 1 : 0) " +
            "addressFocused=\(addressBarFocused ? 1 : 0)"
        )
#endif
        if addressBarFocused {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.webViewClickBlur")
#endif
            setAddressBarFocused(false, reason: "webView.clickIntent")
        }
        if !isFocused {
            onRequestPanelFocus()
        }
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
        refreshBrowserChromeStyle()
        let addressWasEmpty = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        syncURLFromPanel()
        // If we auto-focused a blank omnibar but then a URL loads programmatically, move focus
        // into WebKit unless the user had already started typing.
        if addressBarFocused,
           !panel.shouldSuppressWebViewFocus(),
           addressWasEmpty,
           !isBrowserContentBlankForOmnibar() {
            setAddressBarFocused(false, reason: "panel.currentURL.loaded")
        }
        if panel.isShowingNewTabPage {
            refreshEmptyStateImportBrowsers()
        }
        panel.resetReactGrabState(
            preserveRoundTrip: true,
            reason: "panel.currentURL.changed"
        )
    }

    func handleRenderWebViewChange() {
        refreshBrowserChromeStyle()
        if panel.isShowingNewTabPage {
            refreshEmptyStateImportBrowsers()
        }
    }

    func handleBrowserThemeModeRawChange() {
        let normalizedMode = BrowserThemeSettings.mode(for: browserThemeModeRaw)
        if browserThemeModeRaw != normalizedMode.rawValue {
            browserThemeModeRaw = normalizedMode.rawValue
        }
        panel.setBrowserThemeMode(normalizedMode)
    }

    func handleSystemColorSchemeChange() {
        refreshBrowserChromeStyle()
        panel.refreshAppearanceDrivenColors()
    }

    func handleCommandPaletteVisibilityChange(_ notification: Notification) {
        guard commandPaletteVisibilityNotificationMatchesPanelWindow(notification) else { return }
        applyPendingAddressBarFocusRequestIfNeeded()
    }

    func handleProfileChange() {
        panel.historyStore.loadIfNeeded()
        if addressBarFocused {
            refreshSuggestions()
        }
    }

    func handlePanelVisibilityChange(_ visibleInUI: Bool) {
        let effectiveVisibility = visibleInUI && isCurrentPaneOwner
        panel.noteWebViewVisibility(
            effectiveVisibility,
            reason: effectiveVisibility ? "view.visible" : "view.hidden"
        )
        if visibleInUI {
            panel.cancelPendingDeveloperToolsVisibilityLossCheck()
            return
        }
        if panel.shouldUseLocalInlineDeveloperToolsHosting() {
            // Workspace switches keep the attached inspector alive off-screen.
            // Treating that hide as a manual X-close can clear the restore intent
            // before the original local-inline host becomes visible again.
            panel.cancelPendingDeveloperToolsVisibilityLossCheck()
            return
        }
        // Pane/workspace churn can briefly mark the browser hidden before the
        // final host settles. Only treat a stable hide as a signal to consume
        // an attached-inspector X-close.
        panel.scheduleDeveloperToolsVisibilityLossCheck()
    }

    func handlePanelFocusChange(_ focused: Bool) {
#if DEBUG
        logBrowserFocusState(
            event: "panelFocus.onChange",
            detail: "next=\(focused ? 1 : 0)"
        )
#endif
        // Ensure this view doesn't retain focus while hidden (bonsplit keepAllAlive).
        if focused {
            applyPendingAddressBarFocusRequestIfNeeded()
            autoFocusOmnibarIfBlank()
        } else {
            panel.invalidateAddressBarPageFocusRestoreAttempts()
            panel.clearBrowserFocusMode(reason: "panelFocus.onChange.unfocused")
            hideSuggestions()
            setAddressBarFocused(false, reason: "panelFocus.onChange.unfocused")
            // Surface switches in split layouts can keep the browser visible, so
            // `isVisibleInUI` never flips to false. Check for an attached-inspector
            // X-close when focus leaves as well so the persisted intent stays in sync.
            DispatchQueue.main.async {
                guard isVisibleInUI else { return }
                panel.scheduleDeveloperToolsVisibilityLossCheck()
            }
        }
        syncWebViewResponderPolicyWithViewState(
            reason: "panelFocusChanged",
            isPanelFocusedOverride: focused
        )
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
            panel.beginSuppressWebViewFocusForAddressBar()
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
        syncWebViewResponderPolicyWithViewState(reason: "addressBarFocusChanged")
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

}
