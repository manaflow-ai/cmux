import AppKit
import Foundation
import WebKit

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

        if wasRenderable, hasRecoveryTarget, let recoveryURL {
            pendingWebContentRecoveryURL = recoveryURL
            hasRecoverableWebContentTermination = true
            closeBackgroundPreloadHost(reason: "webContentRecovery")
            detachTerminatedWebViewCallbacks(terminatedWebView)
            hideBrowserPortalView(source: "webContentRecovery")
        } else {
            clearWebContentTerminationRecovery()
        }
        _ = resetMediaStateAfterWebContentTermination()
        refreshNavigationAvailability()
        refreshWebViewLifecycleState()

#if DEBUG
        cmuxDebugLog(
            "browser.webcontent.terminated panel=\(id.uuidString.prefix(5)) " +
            "renderable=\(wasRenderable ? 1 : 0) recoveryURL=\(recoveryURLString ?? "nil") " +
            "manualRecovery=\(hasRecoverableWebContentTermination ? 1 : 0)"
        )
#endif
    }

    func detachTerminatedWebViewCallbacks(_ terminatedWebView: WKWebView) {
        detachWebViewObservers()
        tearDownReactGrabMessageHandler(for: terminatedWebView, reason: "webContentProcessTerminated")
        tearDownMediaPlaybackMessageHandler(for: terminatedWebView)
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

        detachWebViewObservers()
        clearBrowserFocusMode(reason: reason)
        faviconTask?.cancel()
        faviconTask = nil
        faviconRefreshGeneration &+= 1
        loadingGeneration &+= 1
        loadingEndScheduler.cancel()
        isLoading = false
        estimatedProgress = 0
        cancelPendingInteractiveBrowserPrompts(reason: reason)
        closeBackgroundPreloadHost(reason: reason)
        BrowserWindowPortalRegistry.detach(webView: oldWebView)
        webAuthnCoordinator.tearDown(from: oldWebView); oldWebView.stopLoading()
        isMainFrameProvisionalNavigationActive = false
        oldWebView.navigationDelegate = nil
        oldWebView.uiDelegate = nil
        if let oldCmuxWebView = oldWebView as? CmuxWebView { oldCmuxWebView.clearBrowserDownloadCallbacks() }

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
        pendingWebContentRecoveryURL = nil
        hasRecoverableWebContentTermination = false
    }

}
