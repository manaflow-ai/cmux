import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Focus & Responder Management
extension BrowserPanelView {
    func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }

    func refreshBrowserChromeStyle() {
        browserChromeStyle = BrowserChromeStyle.resolve(
            for: colorScheme,
            themeBackgroundColor: GhosttyBackgroundTheme.currentColor(),
            drawsBackground: panel.drawsConfiguredWebViewBackgroundForCurrentPage()
        )
    }

    func syncWebViewResponderPolicyWithViewState(
        reason: String,
        isPanelFocusedOverride: Bool? = nil
    ) {
        guard let cmuxWebView = panel.webView as? CmuxWebView else { return }
        let isPanelFocused = isPanelFocusedOverride ?? isFocused
        let next = isPanelFocused && !panel.shouldSuppressWebViewFocus()
        if cmuxWebView.allowsFirstResponderAcquisition != next {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.policy.resync panel=\(panel.id.uuidString.prefix(5)) " +
                "web=\(ObjectIdentifier(cmuxWebView)) old=\(cmuxWebView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "new=\(next ? 1 : 0) reason=\(reason) " +
                "panelFocusedUsed=\(isPanelFocused ? 1 : 0)"
            )
#endif
        }
        cmuxWebView.allowsFirstResponderAcquisition = next
    }

    private func canHandleOmnibarSelectionNavigation() -> Bool {
        if addressBarFocused {
            return true
        }
        if AppDelegate.shared?.focusedBrowserAddressBarPanelId() == panel.id {
            return true
        }
        let fieldWindow = panel.webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
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

    func browserFocusResponderChainContains(
        _ start: NSResponder?,
        target: NSResponder
    ) -> Bool {
        var current = start
        var hops = 0
        while let responder = current, hops < 64 {
            if responder === target { return true }
            current = responder.nextResponder
            hops += 1
        }
        return false
    }

    private func isPanelFocusedInModel() -> Bool {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId),
              manager.selectedTabId == panel.workspaceId,
              let workspace = manager.tabs.first(where: { $0.id == panel.workspaceId }) else {
            return false
        }
        return workspace.focusedPanelId == panel.id
    }

    func canApplyBrowserFindFieldFocusRequest(_ generation: UInt64) -> Bool {
        isPanelFocusedInModel() && panel.canApplySearchFocusRequest(generation)
    }

    func shouldApplyAddressBarExitFallback(in window: NSWindow) -> Bool {
        // Navigation-triggered omnibar blur can still be unwinding when Cmd+F opens
        // the browser find bar. Once find is visible, any delayed omnibar-exit
        // handoff must not reclaim first responder for WebKit.
        panel.webView.window === window &&
            isPanelFocusedInModel() &&
            panel.searchState == nil
    }

#if DEBUG
    private func browserFocusWindow() -> NSWindow? {
        panel.webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func browserFocusResponderDescription(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return String(describing: type(of: responder))
    }

    func logBrowserFocusState(event: String, detail: String = "") {
        let window = browserFocusWindow()
        let firstResponder = window?.firstResponder
        let firstResponderType = browserFocusResponderDescription(firstResponder)
        let webResponder = browserFocusResponderChainContains(firstResponder, target: panel.webView) ? 1 : 0
        var line =
            "browser.focus.trace event=\(event) panel=\(panel.id.uuidString.prefix(5)) " +
            "panelFocused=\(isFocused ? 1 : 0) addrFocused=\(addressBarFocused ? 1 : 0) " +
            "suppressWeb=\(panel.shouldSuppressWebViewFocus() ? 1 : 0) " +
            "suppressAuto=\(panel.shouldSuppressOmnibarAutofocus() ? 1 : 0) " +
            "webResponder=\(webResponder) win=\(window?.windowNumber ?? -1) fr=\(firstResponderType)"
        if let pending = panel.pendingAddressBarFocusRequestId {
            line += " pending=\(pending.uuidString.prefix(8))"
        }
        if !detail.isEmpty {
            line += " \(detail)"
        }
        cmuxDebugLog(line)
    }
#endif

    func syncURLFromPanel() {
        let urlString = panel.preferredURLStringForOmnibar() ?? ""
        let effects = omnibarReduce(state: &omnibarState, event: .panelURLChanged(currentURLString: urlString))
        applyOmnibarEffects(effects)
    }

    func isCommandPaletteVisibleForPanelWindow() -> Bool {
        guard let app = AppDelegate.shared else { return false }

        if let window = panel.webView.window, app.isCommandPaletteVisible(for: window) {
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
           panel.webView.window === notificationWindow {
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
        guard panel.panelType == .browser else {
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
        panel.beginSuppressWebViewFocusForAddressBar()
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

}
