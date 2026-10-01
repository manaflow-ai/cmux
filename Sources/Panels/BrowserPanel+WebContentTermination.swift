import AppKit
import CmuxBrowser
import Foundation
import WebKit

extension BrowserPanel {
    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var responder = start
        var hops = 0
        while let current = responder, hops < 64 {
            if current === target { return true }
            responder = current.nextResponder
            hops += 1
        }
        return false
    }
}

extension BrowserPanel {
    func handleWebContentProcessTermination(for terminatedWebView: WKWebView) {
        guard terminatedWebView === webView else { return }

        let wasRenderable = shouldRenderWebView
        let attemptedURL = Self.remoteProxyDisplayURL(for: navigationDelegate?.lastAttemptedURL)
            ?? navigationDelegate?.lastAttemptedURL
        let liveURL = restorableDisplayURLForCurrentErrorPage(liveURL: terminatedWebView.url)
        let recoveryURL = (isMainFrameProvisionalNavigationActive ? attemptedURL : nil)
            ?? liveURL
            ?? attemptedURL
            ?? resolvedCurrentSessionHistoryURL()
        let recoveryURLString = recoveryURL?.absoluteString
        let hasRecoveryTarget = recoveryURLString != nil && recoveryURLString != blankURLString

        loadingGeneration &+= 1
        loadingEndScheduler.cancel()
        isMainFrameProvisionalNavigationActive = false
        isLoading = false
        estimatedProgress = 0
        clearBrowserFocusMode(reason: "webContentProcessTerminated")
        invalidateSearchFocusRequests(reason: "webContentProcessTerminated")
        if let window = terminatedWebView.window,
           Self.responderChainContains(window.firstResponder, target: terminatedWebView) {
            window.makeFirstResponder(nil)
        }
        cancelPendingInteractiveBrowserPrompts(reason: "webContentProcessTerminated")

        // WebKit keeps the back/forward list after the process dies, so a pane
        // hidden at the time restores that state when shown. One that was
        // shown waits for an explicit reload, so a page that crashes its
        // process cannot reload itself in a loop.
        webContentState = .terminated(
            recoveryURL: hasRecoveryTarget ? recoveryURL : nil,
            restoresWhenShown: wasRenderable && !isWebViewVisibleInUI
        )
        // The terminated WebContent process can no longer deliver either the native
        // navigation delegate commit or the isolated document-ready bridge. Revoke the
        // generation's readiness before detaching callbacks so socket workers cannot
        // continue treating the dead document as executable.
        automationDocumentReadiness.invalidate()
        hasCommittedDocumentSinceWebViewReplacement = false
        detachTerminatedWebViewCallbacks(terminatedWebView)
        if wasRenderable {
            closeBackgroundPreloadHost(reason: "webContentRecovery")
            hideBrowserPortalView(source: "webContentRecovery")
        }
        _ = resetMediaStateAfterWebContentTermination()
        refreshNavigationAvailability()
        refreshWebViewLifecycleState()

#if DEBUG
        cmuxDebugLog(
            "browser.webcontent.terminated panel=\(id.uuidString.prefix(5)) " +
            "renderable=\(wasRenderable ? 1 : 0) recoveryURL=\(recoveryURLString ?? "nil") " +
            "restoresWhenShown=\(webContentState.restoresWhenShown ? 1 : 0)"
        )
#endif
    }

    func detachTerminatedWebViewCallbacks(_ terminatedWebView: WKWebView) {
        detachWebViewObservers()
        tearDownReactGrabMessageHandler(for: terminatedWebView, reason: "webContentProcessTerminated")
        tearDownMediaPlaybackMessageHandler(for: terminatedWebView); tearDownPageRestoration(for: terminatedWebView)
        webAuthnCoordinator.tearDown(from: terminatedWebView)
        terminatedWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserSSLTrustBypassMessageHandler.name
        )
        terminatedWebView.navigationDelegate = nil
        terminatedWebView.uiDelegate = nil
        if let terminatedCmuxWebView = terminatedWebView as? CmuxWebView {
            terminatedCmuxWebView.cmuxDownloadDelegate = nil
            terminatedCmuxWebView.clearBrowserDownloadCallbacks()
        }
    }

    @discardableResult
    func replaceWebViewPreservingState(
        from oldWebView: WKWebView,
        websiteDataStore: WKWebsiteDataStore,
        reason: String,
        overrideRestoreURL: URL? = nil,
        restoreAfterReplacement: Bool = true
    ) -> Bool {
        guard oldWebView === webView else { return false }

        let wasRenderable = shouldRenderWebView
        let attemptedURL = Self.remoteProxyDisplayURL(for: navigationDelegate?.lastAttemptedURL)
            ?? navigationDelegate?.lastAttemptedURL
        let liveURL = restorableDisplayURLForCurrentErrorPage(liveURL: oldWebView.url)
        let restoreURL = overrideRestoreURL
            ?? (isMainFrameProvisionalNavigationActive ? attemptedURL : nil)
            ?? liveURL
            ?? attemptedURL
            ?? resolvedCurrentSessionHistoryURL()
        let restoreURLString = restoreURL?.absoluteString
        let hasRecoveryTarget = restoreURLString != nil && restoreURLString != blankURLString
        let shouldRestoreURL = wasRenderable && hasRecoveryTarget
        let history = sessionNavigationHistorySnapshot()
        let historyCurrentURL = preferredURLStringForOmnibar()
        let desiredZoom = max(minPageZoom, min(maxPageZoom, oldWebView.pageZoom))
        let restoreDevTools = preferredDeveloperToolsVisible

        if oldWebView.configuration.websiteDataStore !== websiteDataStore {
            navigationDelegate?.clearSSLTrustState()
        }

#if DEBUG
        cmuxDebugLog(
            "browser.webview.replace.begin panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) " +
            "renderable=\(wasRenderable ? 1 : 0) restoreURL=\(restoreURLString ?? "nil") " +
            "restoreHistoryBack=\(history.backHistoryURLStrings.count) " +
            "restoreHistoryForward=\(history.forwardHistoryURLStrings.count)"
        )
#endif

        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        loadingGeneration &+= 1
        loadingEndScheduler.cancel()
        isLoading = false
        estimatedProgress = 0
        cancelPendingInteractiveBrowserPrompts(reason: reason)
        closeBackgroundPreloadHost(reason: reason)
        isMainFrameProvisionalNavigationActive = false
        tearDownWebViewBeforeReplacement(oldWebView, reason: reason)

        let replacement = makeReplacementWebView(
            profileID: profileID,
            websiteDataStore: websiteDataStore
        )
        replacement.pageZoom = desiredZoom
        webViewInstanceID = UUID()
        hasCommittedDocumentSinceWebViewReplacement = false; userStoppedLoadSinceWebViewReplacement = false
        resetWebViewLifecycleMetadata(resetVisibility: false)
        webView = replacement
        shouldRenderWebView = wasRenderable
        refreshWebViewLifecycleState()

        bindWebView(replacement)
        applyBrowserThemeModeIfNeeded()

        if !history.backHistoryURLStrings.isEmpty || !history.forwardHistoryURLStrings.isEmpty {
            restoreSessionNavigationHistory(
                backHistoryURLStrings: history.backHistoryURLStrings,
                forwardHistoryURLStrings: history.forwardHistoryURLStrings,
                currentURLString: historyCurrentURL
            )
        }

        clearWebContentTerminationRecovery()
        if !restoreAfterReplacement {
            refreshNavigationAvailability()
        } else {
            if shouldRestoreURL, let restoreURL {
                navigateWithoutInsecureHTTPPrompt(
                    to: restoreURL,
                    recordTypedNavigation: false,
                    preserveRestoredSessionHistory: true
                )
            } else {
                refreshNavigationAvailability()
            }
        }

        if restoreDevTools {
            requestDeveloperToolsRefreshAfterNextAttach(reason: reason)
        }

#if DEBUG
        cmuxDebugLog(
            "browser.webview.replace.end panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) " +
            "instance=\(webViewInstanceID.uuidString.prefix(6)) " +
            "restoreURL=\(restoreURLString ?? "nil") shouldRestore=\(shouldRestoreURL ? 1 : 0)"
        )
#endif
        return true
    }

    @discardableResult
    func recoverTerminatedWebContent(
        reason: String = "manual",
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) -> Bool {
        guard hasRecoverableWebContentTermination else { return false }
        let recoveryURL = pendingWebContentRecoveryURL
        let terminatedWebView = webView
        guard replaceWebViewPreservingState(
            from: terminatedWebView,
            websiteDataStore: websiteDataStore,
            reason: "webcontent_recovery.\(reason)",
            overrideRestoreURL: recoveryURL,
            restoreAfterReplacement: false
        ) else {
            clearWebContentTerminationRecovery()
            refreshNavigationAvailability()
            return true
        }
#if DEBUG
        cmuxDebugLog(
            "browser.webcontent.recover panel=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) url=\(recoveryURL?.absoluteString ?? "nil")"
        )
#endif
        guard let recoveryURL else {
            refreshNavigationAvailability()
            return true
        }
        navigateWithoutInsecureHTTPPrompt(
            to: recoveryURL,
            recordTypedNavigation: false,
            preserveRestoredSessionHistory: true,
            cachePolicy: cachePolicy
        )
        return true
    }

    func clearWebContentTerminationRecovery() {
        webContentState = .active
    }

    /// Turns a pane whose process died while hidden into a discarded pane,
    /// so the caller's restore brings back its last session state instead of
    /// showing the Reload overlay.
    ///
    /// - Returns: Whether the pane was converted.
    @discardableResult
    func discardWebViewTerminatedWhileHidden(now: Date = Date()) -> Bool {
        guard webContentState.restoresWhenShown, !isClosingWebViewLifecycle else { return false }
        dropWebViewForDiscard(reason: Self.hiddenWebContentTerminationDiscardReason, now: now)
        return true
    }

    static let hiddenWebContentTerminationDiscardReason = "webcontent_terminated_hidden"
}

extension BrowserPanel.WebContentState {
    /// Whether the process died while the pane was hidden, so showing the
    /// pane restores its page instead of waiting for a reload.
    var restoresWhenShown: Bool {
        if case .terminated(_, let restoresWhenShown) = self { return restoresWhenShown }
        return false
    }
}
