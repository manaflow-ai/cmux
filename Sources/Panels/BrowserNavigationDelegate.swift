import AppKit
import CmuxBrowser
import CmuxSettings
import Foundation
import WebKit

@MainActor final class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    enum PolicyCancellationKind { case terminal(restoreAttemptID: UUID?) }
    private let subframeDownloadIntents = BrowserSubframeDownloadIntentTracker()
    private let externalNavigationPolicy = BrowserExternalNavigationPolicy(
        trustedOrigin: AuthEnvironment.appWebOrigin
    )
    private var shouldPrintAfterCurrentNavigationFinishes = false
    var didStartProvisionalNavigation: ((WKWebView, WKNavigation?) -> Void)?
    var didCommit: ((WKWebView, WKNavigation?) -> Void)?
    var didFinish: ((WKWebView) -> Void)?
    var didFailNavigation: ((WKWebView, String, String, WKNavigation?) -> Void)?
    var didCancelProvisionalNavigation: ((WKWebView, WKNavigation?) -> Void)?
    var didChooseMainFrameDownloadPolicy: ((WKWebView, WKNavigation?) -> Void)?
    var didInterruptProvisionalNavigationByPolicy: ((WKWebView, WKNavigation?) -> Bool)?
    var didCancelNavigationPolicy: ((WKWebView, PolicyCancellationKind) -> Void)?
    var didBecomeDownload: ((WKWebView, Bool, UUID?) -> Void)?
    var didTerminateWebContentProcess: ((WKWebView) -> Void)?
    var handleBlockedURLAllowlistNavigation: ((URL, WKWebView) -> Void)?
    var openInNewTab: ((URL) -> Void)?
    var openAppLinkInBrowserSplit: ((URL) -> Bool)?
    var requestNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent, ((WKNavigation?) -> Void)?) -> Void)?
    var presentAlert: BrowserAlertPresenter = browserPresentAlert
    var shouldBlockInsecureHTTPNavigation: ((URL) -> Bool)?
    var shouldBlockInsecureHTTPSubframeDownload: ((URL) -> Bool)?
    var handleBlockedInsecureHTTPNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    var handleDroppedFileNavigation: (([URL]) -> Bool)?
    var currentRestoreAttemptID: (() -> UUID?)?
    var terminalPolicyCancellationReporter: ((WKNavigationAction, WKWebView) -> () -> Void)?
    var willReplaceNavigationForUserAgentPolicy: ((WKWebView, WKNavigation?) -> Void)?
    var didReplaceNavigationForUserAgentPolicy: ((WKWebView, WKNavigation?, WKNavigation?) -> Void)?
    var didRenderPDFDocument: ((URL, Bool) -> Void)?
    var didClearPDFDocument: (() -> Void)?
    var artifactHTMLPreviewPolicy: ArtifactHTMLPreviewNavigationPolicy?
    /// Direct reference to the download delegate - must be set synchronously in didBecome callbacks.
    var downloadDelegate: WKDownloadDelegate?
    /// Last attempted navigation URL, used to preserve the omnibar URL after provisional failures.
    var lastAttemptedURL: URL?
    private(set) var activeErrorPageDisplayURL: URL?
    private(set) var activePolicyBlockedURL: URL?
    private let basicAuthPromptCoordinator = BrowserHTTPBasicAuthPromptCoordinator()
    private let clientCertificateAuthenticationController = BrowserClientCertificateAuthenticationController()
    weak var owner: BrowserPanel?
    private let sslBypassState = BrowserSSLTrustBypassState()
    private var lastAttemptedRequest: URLRequest?
    private var lastAttemptedRequestWasDiscardedForReplay = false
    private var acceptsSSLTrustBypassMessages = false
    private var activeSSLTrustBypassErrorPageFailedURL: String?
    private var activeSSLTrustBypassReplayRequest: URLRequest?
    private var activeSSLTrustBypassErrorPageRetryRequest: URLRequest?
    private var pendingMainFrameDownloadRestoreAttemptID: UUID?
    private var trustedInternalNavigationURL: URL?
    // WKNavigation is WebKit's only public identity linking a load to its lifecycle callbacks.
    private var activeMainFrameNavigation: WKNavigation?

    func cancelPendingAuthenticationPrompts(allowFuturePrompts: Bool = false) {
        basicAuthPromptCoordinator.cancelAll(allowFuturePrompts: allowFuturePrompts)
        clientCertificateAuthenticationController.cancelAll(allowFuturePrompts: allowFuturePrompts)
    }

    func recordAttemptedRequest(_ request: URLRequest, displayURL: URL? = nil) {
        sslBypassState.beginObservingServerTrustForNavigation()
        acceptsSSLTrustBypassMessages = false
        activeSSLTrustBypassErrorPageFailedURL = nil
        activeSSLTrustBypassReplayRequest = nil
        activeSSLTrustBypassErrorPageRetryRequest = nil
        activeErrorPageDisplayURL = nil
        activePolicyBlockedURL = nil
        lastAttemptedURL = displayURL ?? request.url
        if sslBypassState.canRetainRequestForReplay(request) {
            lastAttemptedRequest = request
            lastAttemptedRequestWasDiscardedForReplay = false
        } else {
            lastAttemptedRequest = nil
            lastAttemptedRequestWasDiscardedForReplay = true
        }
    }

    func clearAttemptedRequest(discardPendingBypasses: Bool = false) {
        if discardPendingBypasses {
            sslBypassState.clearPendingBypasses()
            acceptsSSLTrustBypassMessages = false
            activeSSLTrustBypassErrorPageFailedURL = nil
        }
        activeSSLTrustBypassReplayRequest = nil
        activeSSLTrustBypassErrorPageRetryRequest = nil
        activeErrorPageDisplayURL = nil
        activePolicyBlockedURL = nil
        lastAttemptedRequest = nil
        lastAttemptedRequestWasDiscardedForReplay = false
        lastAttemptedURL = nil
    }

    func clearSSLTrustState() {
        sslBypassState.clearAllTrustState()
        acceptsSSLTrustBypassMessages = false
        activeSSLTrustBypassErrorPageFailedURL = nil
        activeSSLTrustBypassReplayRequest = nil
        activeSSLTrustBypassErrorPageRetryRequest = nil
        activeErrorPageDisplayURL = nil
        activePolicyBlockedURL = nil
        lastAttemptedRequest = nil
        lastAttemptedRequestWasDiscardedForReplay = false
        lastAttemptedURL = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        activeMainFrameNavigation = navigation
        lastAttemptedURL = lastAttemptedURL ?? webView.url ?? lastAttemptedRequest?.url
        shouldPrintAfterCurrentNavigationFinishes = false
        didClearPDFDocument?()
        didStartProvisionalNavigation?(webView, navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if activeSSLTrustBypassReplayRequest != nil || activeSSLTrustBypassErrorPageRetryRequest != nil {
            clearAttemptedRequest(discardPendingBypasses: true)
        }
        didCommit?(webView, navigation)
        trustedInternalNavigationURL = nil
        clearActiveMainFrameNavigation(ifMatching: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish?(webView)
        trustedInternalNavigationURL = nil
        clearActiveMainFrameNavigation(ifMatching: navigation)
        if shouldPrintAfterCurrentNavigationFinishes {
            shouldPrintAfterCurrentNavigationFinishes = false
            webView.cmuxRunPrintOperation()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("BrowserPanel navigation failed: %@", error.localizedDescription)
        // Treat committed-navigation failures the same as provisional ones so
        // stale favicon/title state from the prior page gets cleared.
        let failedURL = webView.url?.absoluteString ?? ""
        didFailNavigation?(webView, failedURL, error.localizedDescription, navigation)
        trustedInternalNavigationURL = nil
        clearActiveMainFrameNavigation(ifMatching: navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        trustedInternalNavigationURL = nil
        let nsError = error as NSError
        NSLog("BrowserPanel provisional navigation failed: %@", error.localizedDescription)

        // Cancelled navigations (e.g. rapid typing) are not real errors.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            didCancelProvisionalNavigation?(webView, navigation)
            clearActiveMainFrameNavigation(ifMatching: navigation)
            return
        }

        // "Frame load interrupted" (WebKitErrorDomain code 102) can result from
        // several policy transfers. Only an explicit .download decision is success.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            let isDownload = didInterruptProvisionalNavigationByPolicy?(webView, navigation) == true
            if !isDownload {
                didCancelProvisionalNavigation?(webView, navigation)
            }
            clearActiveMainFrameNavigation(ifMatching: navigation)
            return
        }

        let failedURL = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            ?? lastAttemptedURL?.absoluteString
            ?? ""
        didFailNavigation?(webView, failedURL, error.localizedDescription, navigation)
        clearActiveMainFrameNavigation(ifMatching: navigation)
        loadErrorPage(
            in: webView,
            failedURL: failedURL,
            retry: retryForFailedNavigation(failedURL: failedURL),
            error: nsError
        )
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           BrowserSSLTrustScope(protectionSpace: challenge.protectionSpace) != nil {
            if sslBypassState.isBypassed(protectionSpace: challenge.protectionSpace, serverTrust: trust) {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            sslBypassState.recordObservedServerTrust(trust, for: challenge.protectionSpace)
        }

        if basicAuthPromptCoordinator.handle(
            challenge: challenge,
            startPrompt: { [presentAlert, owner] finishPrompt, registerCancelPrompt in
                browserHandleHTTPBasicAuthenticationChallenge(
                    in: webView,
                    challenge: challenge,
                    presentAlert: presentAlert,
                    browserPanel: owner,
                    registerCancelPrompt: registerCancelPrompt,
                    completionHandler: finishPrompt
                )
            },
            completionHandler: completionHandler
        ) {
            return
        }

        if clientCertificateAuthenticationController.handle(
            challenge: challenge,
            in: webView,
            presentAlert: { [weak owner, presentAlert] alert, webView, completion, cancel in
                if let owner {
                    owner.presentMobileClientCertificateAlert(
                        alert,
                        webView: webView,
                        completion: completion,
                        cancel: cancel
                    )
                } else {
                    presentAlert(alert, webView, completion, cancel)
                }
            },
            completionHandler: completionHandler
        ) {
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
#if DEBUG
        cmuxDebugLog("browser.webcontent.terminated panel=\(String(describing: self))")
#endif
        didTerminateWebContentProcess?(webView)
    }

    private func retryForFailedNavigation(failedURL: String) -> BrowserErrorPageRetry {
        if let lastAttemptedRequest {
            guard lastAttemptedRequest.url != nil,
                  lastAttemptedRequest.browserMatchesFailedNavigationURLString(failedURL) else {
                return lastAttemptedRequest.browserCanReloadWithURLOnly ? .urlOnly : .disabled
            }
            return .request(lastAttemptedRequest)
        }
        if lastAttemptedRequestWasDiscardedForReplay {
            return .disabled
        }
        return .urlOnly
    }

    func activeErrorPageRetryForAutomation() -> BrowserErrorPageRetry? {
        guard activePolicyBlockedURL == nil else { return .disabled }
        guard let failedURL = activeErrorPageDisplayURL?.absoluteString else { return nil }
        return retryForFailedNavigation(failedURL: failedURL)
    }

    private func loadErrorPage(in webView: WKWebView, failedURL: String, retry: BrowserErrorPageRetry, error: NSError) {
        activeSSLTrustBypassReplayRequest = nil
        activeSSLTrustBypassErrorPageRetryRequest = nil
        activeErrorPageDisplayURL = URL(string: failedURL)
        let canBypass = BrowserErrorPage(
            failedURL: failedURL,
            retry: retry,
            error: error,
            sslBypassState: sslBypassState
        ).load(in: webView)
        acceptsSSLTrustBypassMessages = canBypass
        activeSSLTrustBypassErrorPageFailedURL = canBypass ? failedURL : nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let decisionHandler = BrowserNavigationActionDecisionHandler(
            decisionHandler,
            fallbackPolicy: WKNavigationActionPolicy.cancel,
            label: "BrowserNavigationDelegate.navigationAction"
        ).closure

        let artifactNavigationAllowed = artifactHTMLPreviewPolicy?.allowsNavigation(
            to: navigationAction.request.url,
            targetIsMainFrame: navigationAction.targetFrame?.isMainFrame
        ) == true
        if artifactHTMLPreviewPolicy != nil, !artifactNavigationAllowed {
            decisionHandler(.cancel)
            return
        }
        if let url = navigationAction.request.url,
           url.scheme == "cmux-browser-action",
           url.host == "bypass-ssl" {
            decisionHandler(.cancel)
            handleSSLTrustBypassAction(url, in: webView)
            return
        }

        if let url = navigationAction.request.url {
            let isTrustedInternal = trustedInternalNavigation(for: url, in: webView)
            let isMainFrame = navigationAction.targetFrame?.isMainFrame != false
            if !artifactNavigationAllowed,
               !isTrustedInternal,
               url.scheme?.lowercased() != AuthEnvironment.callbackScheme.lowercased(),
               !BrowserURLAllowlistPolicy(defaults: .standard).allows(url) {
                decisionHandler(.cancel)
                if isMainFrame {
                    blockURLAllowlistNavigation(url, in: webView)
                }
                return
            }
        }

        if let url = navigationAction.request.url,
           BrowserFileDropNavigationGuard.isDropFallbackNavigation(
               url: url,
               isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
               navigationType: navigationAction.navigationType
           ),
           let droppedURLs = BrowserFileDropNavigationGuard.shared.consumeDropNavigation(webView: webView, url: url),
           handleDroppedFileNavigation?(droppedURLs) == true {
#if DEBUG
            cmuxDebugLog("browser.nav.decidePolicy.action kind=dropFilePreview url=\(browserNavigationDebugURL(url))")
#endif
            decisionHandler(.cancel)
            return
        }

        let openRequestInNewTab: (URLRequest) -> Void = { [requestNavigation, openInNewTab] request in
            if let requestNavigation {
                requestNavigation(request, .newTab, nil)
                return
            }
            if let url = request.url {
                openInNewTab?(url)
            }
        }
        let hasRecentMiddleClickIntent = CmuxWebView.hasRecentMiddleClickIntent(for: webView)
        let shouldOpenInNewTab = browserNavigationShouldOpenInNewTab(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            hasRecentMiddleClickIntent: hasRecentMiddleClickIntent
        )
        let hasUserActivation = browserNavigationHasSimpleUserActivation()
        subframeDownloadIntents.updateIfNeeded(navigationAction, hasUserActivation: hasUserActivation)
        if navigationAction.targetFrame?.isMainFrame == true {
            pendingMainFrameDownloadRestoreAttemptID = currentRestoreAttemptID?()
        }
#if DEBUG
        let currentEventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
        let currentEventButton = NSApp.currentEvent.map { String($0.buttonNumber) } ?? "nil"
        let navType = String(describing: navigationAction.navigationType)
        let requestMethod = navigationAction.request.httpMethod ?? "nil"
        let requestURL = browserNavigationDebugURL(navigationAction.request.url)
        let targetMainFrame = navigationAction.targetFrame.map { $0.isMainFrame ? "1" : "0" } ?? "nil"
        cmuxDebugLog(
            "browser.nav.decidePolicy navType=\(navType) button=\(navigationAction.buttonNumber) " +
            "mods=\(navigationAction.modifierFlags.rawValue) targetNil=\(navigationAction.targetFrame == nil ? 1 : 0) " +
            "targetMain=\(targetMainFrame) method=\(requestMethod) url=\(requestURL) " +
            "eventType=\(currentEventType) eventButton=\(currentEventButton) " +
            "recentMiddleIntent=\(hasRecentMiddleClickIntent ? 1 : 0) " +
            "openInNewTab=\(shouldOpenInNewTab ? 1 : 0)"
        )
#endif

        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame != false,
           let url = navigationAction.request.url,
           let appLink = BrowserAppLinkOpenRequest(
               url: url,
               webOrigin: AuthEnvironment.appSessionHandoffOrigin
           ),
           openAppLinkInBrowserSplit?(appLink.destinationURL) == true {
            clearAttemptedRequest(discardPendingBypasses: true)
            let reportTerminalCancellation = terminalPolicyCancellationReporter?(
                navigationAction,
                webView
            ) ?? {}
            reportTerminalCancellation()
#if DEBUG
            cmuxDebugLog(
                "browser.nav.decidePolicy.action kind=openAppLinkInBrowserSplit " +
                "url=\(browserNavigationDebugURL(appLink.destinationURL))"
            )
#endif
            decisionHandler(.cancel)
            return
        }

        if let url = navigationAction.request.url,
           shouldOpenInSystemBrowser(navigationAction, url: url) {
            clearAttemptedRequest(discardPendingBypasses: true)
            let reportTerminalCancellation = terminalPolicyCancellationReporter?(navigationAction, webView) ?? {}
            let opened = NSWorkspace.shared.open(url)
#if DEBUG
            cmuxDebugLog(
                "browser.nav.decidePolicy.action kind=openExternalIntentInSystemBrowser opened=\(opened ? 1 : 0) " +
                "url=\(browserNavigationDebugURL(url))"
            )
#endif
            if opened {
                reportTerminalCancellation()
            } else if restartNavigationForUserAgentPolicyIfNeeded(
                navigationAction,
                in: webView,
                decisionHandler: decisionHandler
            ) {
                return
            }
            decisionHandler(opened ? .cancel : .allow)
            return
        }

        if handleAuthCallbackNavigationAction(navigationAction, webView: webView, decisionHandler: decisionHandler) {
            return
        }

        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame != false,
           shouldBlockInsecureHTTPNavigation?(url) == true {
            let intent: BrowserInsecureHTTPNavigationIntent
            if shouldOpenInNewTab || navigationAction.targetFrame == nil {
                intent = .newTab
            } else {
                intent = .currentTab
            }
#if DEBUG
            cmuxDebugLog(
                "browser.nav.decidePolicy.action kind=blockedInsecure intent=\(intent == .newTab ? "newTab" : "currentTab") " +
                "url=\(url.absoluteString)"
            )
#endif
            handleBlockedInsecureHTTPNavigation?(navigationAction.request, intent)
            decisionHandler(.cancel)
            return
        }

        if let url = navigationAction.request.url,
           browserShouldRouteExternalNavigation(url) {
            clearAttemptedRequest(discardPendingBypasses: true)
            let reportTerminalCancellation = terminalPolicyCancellationReporter?(navigationAction, webView) ?? {}
            // WKNavigationAction has no public WKNavigation identity. Keep the replacement
            // unbound so the exact original policy cancellation terminates automation.
            browserHandleExternalNavigation(
                url,
                source: "navDelegate",
                webView: webView,
                loadFallbackRequest: { [requestNavigation] request in
                    requestNavigation?(request, .currentTab, nil)
                },
                presentAlert: presentAlert,
                onTerminalExternalNavigation: reportTerminalCancellation
            )
            decisionHandler(.cancel)
            return
        }

        if navigationAction.shouldPerformDownload {
            // Action-policy downloads expose no WKNavigation identity. Only a response-policy
            // conversion can authorize automation success for an exact provisional navigation.
            if navigationAction.targetFrame?.isMainFrame == false {
                guard let url = navigationAction.request.url else {
                    decisionHandler(.cancel)
                    return
                }
                let hasRecordedIntent = subframeDownloadIntents.consume(for: url)
                guard hasUserActivation || hasRecordedIntent else { decisionHandler(.cancel); return }
                if shouldBlockInsecureHTTPSubframeDownload?(url) == true {
                    #if DEBUG
                    cmuxDebugLog("browser.nav.decidePolicy.action kind=cancelDownload reason=insecureHTTPSubframe url=\(url.absoluteString)")
                    #endif
                    decisionHandler(.cancel)
                    return
                }
            }
            clearAttemptedRequest(discardPendingBypasses: true)
            decisionHandler(.download)
            return
        }

        // Cmd+click and middle-click on regular links should always open in a new tab.
        if shouldOpenInNewTab,
           let requestURL = navigationAction.request.url {
#if DEBUG
            cmuxDebugLog(
                "browser.nav.decidePolicy.action kind=openInNewTab url=\(requestURL.absoluteString)"
            )
#endif
            clearAttemptedRequest(discardPendingBypasses: true)
            let reportTerminalCancellation = terminalPolicyCancellationReporter?(navigationAction, webView) ?? {}
            openRequestInNewTab(navigationAction.request)
            reportTerminalCancellation()
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame == nil,
           browserNavigationShouldFallbackNilTargetToNewTab(
               navigationType: navigationAction.navigationType
           ),
           let requestURL = navigationAction.request.url {
#if DEBUG
            cmuxDebugLog(
                "browser.nav.decidePolicy.action kind=openInNewTabFromNilTarget url=\(requestURL.absoluteString)"
            )
#endif
            clearAttemptedRequest(discardPendingBypasses: true)
            let reportTerminalCancellation = terminalPolicyCancellationReporter?(navigationAction, webView) ?? {}
            openRequestInNewTab(navigationAction.request)
            reportTerminalCancellation()
            decisionHandler(.cancel)
            return
        }

#if DEBUG
        let targetURL = navigationAction.request.url?.absoluteString ?? "nil"
        cmuxDebugLog("browser.nav.decidePolicy.action kind=allow url=\(targetURL)")
#endif
        if navigationAction.targetFrame?.isMainFrame != false {
            if shouldPreserveSSLTrustBypassForErrorPageNavigation(navigationAction) {
#if DEBUG
                let targetURL = navigationAction.request.url?.absoluteString ?? "nil"
                cmuxDebugLog("browser.nav.decidePolicy.action kind=preserveSSLBypassErrorPage url=\(targetURL)")
#endif
            } else if let url = navigationAction.request.url,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" {
                recordAttemptedRequest(navigationAction.request)
            } else {
                clearAttemptedRequest()
            }
        }
        if restartNavigationForUserAgentPolicyIfNeeded(
            navigationAction,
            in: webView,
            decisionHandler: decisionHandler
        ) {
            return
        }
        decisionHandler(.allow)
    }

    let authCallbackNavigationPolicy = BrowserAuthCallbackNavigationPolicy(
        trustedSourcePageOrigin: AuthEnvironment.appSessionHandoffOrigin,
        callbackScheme: AuthEnvironment.callbackScheme
    )

    /// Handles auth-callback-shaped navigation actions. Returns `true` when
    /// the navigation was consumed (delivered in-app or blocked); the caller
    /// must stop policy evaluation in that case.
    private func handleAuthCallbackNavigationAction(
        _ navigationAction: WKNavigationAction,
        webView: WKWebView,
        decisionHandler: (WKNavigationActionPolicy) -> Void
    ) -> Bool {
        guard let url = navigationAction.request.url else { return false }
        let disposition = authCallbackNavigationPolicy.disposition(
            for: navigationAction,
            url: url
        )
        return authCallbackNavigationPolicy.consume(
            disposition: disposition,
            callbackURL: url,
            sourcePageURL: webView.url,
            cancelNavigation: { [self] in
                clearAttemptedRequest(discardPendingBypasses: true)
                decisionHandler(.cancel)
            },
            reportTerminalCancellation: { [self] in
                let report = terminalPolicyCancellationReporter?(navigationAction, webView) ?? {}
                report()
            },
            deliver: authCallbackNavigationPolicy.deliverAuthCallbackInApp,
            completion: { [weak self, weak webView] delivered, returnURL in
                guard let self, let webView else { return }
#if DEBUG
                cmuxDebugLog(
                    "browser.nav.decidePolicy.action kind=deliverNativeAuthCallbackInApp " +
                    "delivered=\(delivered ? 1 : 0) scheme=\(url.scheme ?? "nil")"
                )
#endif
                BrowserAuthCallbackNavigationPolicy.finishDelivery(
                    delivered: delivered,
                    returnURL: returnURL,
                    in: webView,
                    prepareReturnRequest: { [weak self] request in
                        self?.recordAttemptedRequest(request)
                    },
                    presentAlert: presentAlert
                )
            }
        )
    }

    private func restartNavigationForUserAgentPolicyIfNeeded(
        _ navigationAction: WKNavigationAction,
        in webView: WKWebView,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) -> Bool {
        guard let requestNavigation else {
            _ = webView.browserUserAgentPolicyRestartRequest(
                for: navigationAction.request,
                targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame
            )
            return false
        }

        let replacedNavigation = activeMainFrameNavigation
        let reportReplacementWillStart = willReplaceNavigationForUserAgentPolicy
        return webView.restartNavigationForBrowserUserAgentPolicyIfNeeded(
            request: navigationAction.request,
            targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame,
            decisionHandler: decisionHandler,
            willRestart: {
                reportReplacementWillStart?(webView, replacedNavigation)
            },
            startReplacement: { restartRequest in
                requestNavigation(restartRequest, .currentTab, { [weak self, weak webView] replacementNavigation in
                    guard let self, let webView else { return }
                    self.didReplaceNavigationForUserAgentPolicy?(
                        webView,
                        replacedNavigation,
                        replacementNavigation
                    )
                })
            }
        )
    }

    private func shouldOpenInSystemBrowser(_ navigationAction: WKNavigationAction, url: URL) -> Bool {
        guard navigationAction.targetFrame?.isMainFrame != false else { return false }
        guard navigationAction.navigationType == .linkActivated else { return false }
        return externalNavigationPolicy.shouldOpenInSystemBrowser(
            url,
            sourceURL: navigationAction.sourceFrame.request.url
                ?? owner?.webView.url
        )
    }

    func canHandleSSLTrustBypassToken(_ token: String) -> Bool {
        acceptsSSLTrustBypassMessages && sslBypassState.hasPendingBypassToken(token)
    }

    func handleSSLTrustBypassToken(_ token: String, in webView: WKWebView) {
        guard acceptsSSLTrustBypassMessages,
              let request = sslBypassState.consumePendingBypassToken(token) else {
            return
        }
        acceptsSSLTrustBypassMessages = false
        activeSSLTrustBypassErrorPageFailedURL = nil
        recordSSLTrustBypassReplayRequest(request)
        browserLoadRequest(request, in: webView)
    }

    func handleSSLTrustBypassAction(_ actionURL: URL, in webView: WKWebView) {
        guard acceptsSSLTrustBypassMessages,
              let request = sslBypassState.consumePendingBypassAction(actionURL) else {
            return
        }
        acceptsSSLTrustBypassMessages = false
        activeSSLTrustBypassErrorPageFailedURL = nil
        recordSSLTrustBypassReplayRequest(request)
        browserLoadRequest(request, in: webView)
    }

    private func recordSSLTrustBypassReplayRequest(_ request: URLRequest) {
        sslBypassState.clearPendingBypasses()
        activeSSLTrustBypassReplayRequest = request
        activeErrorPageDisplayURL = request.url
        lastAttemptedURL = request.url
        lastAttemptedRequest = request
        lastAttemptedRequestWasDiscardedForReplay = false
    }

    private func shouldPreserveSSLTrustBypassForErrorPageNavigation(_ navigationAction: WKNavigationAction) -> Bool {
        let request = navigationAction.request
        guard activeErrorPageDisplayURL != nil,
              navigationAction.navigationType == .other else {
            return false
        }

        guard let url = request.url,
              let scheme = url.scheme?.lowercased() else {
            return true
        }
        guard scheme == "http" || scheme == "https" else {
            return true
        }
        if let replayRequest = activeSSLTrustBypassReplayRequest,
           let replayURL = replayRequest.url?.absoluteString {
            return request.browserMatchesFailedNavigationURLString(replayURL)
        }
        guard acceptsSSLTrustBypassMessages,
              let failedURL = activeSSLTrustBypassErrorPageFailedURL,
              let lastAttemptedRequest else {
            return false
        }
        let preservesErrorPageRetry = request.browserMatchesFailedNavigationURLString(failedURL)
            && request.browserMatchesReplayShape(of: lastAttemptedRequest)
        if preservesErrorPageRetry {
            activeSSLTrustBypassErrorPageRetryRequest = request
        }
        return preservesErrorPageRetry
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let decisionHandler = BrowserNavigationResponseDecisionHandler(
            decisionHandler,
            fallbackPolicy: WKNavigationResponsePolicy.cancel,
            label: "BrowserNavigationDelegate.navigationResponse"
        ).closure

        if let url = navigationResponse.response.url {
            let isTrustedInternal = trustedInternalNavigation(for: url, in: webView)
            let artifactNavigationAllowed = artifactHTMLPreviewPolicy?.allowsNavigation(
                to: url,
                targetIsMainFrame: navigationResponse.isForMainFrame
            ) == true
            if !artifactNavigationAllowed,
               !isTrustedInternal,
               !BrowserURLAllowlistPolicy(defaults: .standard).allows(url) {
                decisionHandler(.cancel)
                if navigationResponse.isForMainFrame {
                    blockURLAllowlistNavigation(url, in: webView)
                }
                return
            }
            if isTrustedInternal {
                trustedInternalNavigationURL = nil
            }
        }

        let mime = navigationResponse.response.mimeType ?? "unknown"
        let canShow = navigationResponse.canShowMIMEType

        if let scheme = navigationResponse.response.url?.scheme?.lowercased(),
           scheme != "http", scheme != "https" {
            decisionHandler(.allow)
            return
        }

        #if DEBUG
        cmuxDebugLog(
            "browser.nav.response mime=\(mime) canShow=\(canShow ? 1 : 0) mainFrame=\(navigationResponse.isForMainFrame ? 1 : 0)"
        )
        #endif

        let contentDisposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        let filenameResolver = BrowserDownloadFilenameResolver()
        let hasTrustedPDFPrintIntent = subframeDownloadIntents.consumePDFPrintIntent(
            responseURL: navigationResponse.response.url,
            mimeType: mime,
            isForMainFrame: navigationResponse.isForMainFrame
        )
        if filenameResolver.shouldPrintPDFAfterLoad(
            mimeType: mime,
            responseURL: navigationResponse.response.url,
            isForMainFrame: navigationResponse.isForMainFrame,
            hasTrustedPrintIntent: hasTrustedPDFPrintIntent
        ) {
            shouldPrintAfterCurrentNavigationFinishes = true
        }
        let isUserActivatedPreviouslyRenderedSubframePDF = subframeDownloadIntents
            .consumeUserActivatedPreviouslyRenderedSubframePDF(
                responseURL: navigationResponse.response.url,
                mimeType: mime,
                isForMainFrame: navigationResponse.isForMainFrame
            )
        let allowsSubframeDownload = navigationResponse.isForMainFrame
            || subframeDownloadIntents.consume(for: navigationResponse.response.url)
            || isUserActivatedPreviouslyRenderedSubframePDF
        if let reason = filenameResolver.navigationResponseDownloadReason(
            mimeType: mime,
            canShowMIMEType: canShow,
            contentDisposition: contentDisposition,
            isForMainFrame: navigationResponse.isForMainFrame,
            allowsSubframeDownload: allowsSubframeDownload,
            isUserActivatedPreviouslyRenderedSubframePDF: isUserActivatedPreviouslyRenderedSubframePDF
        ) {
            if !navigationResponse.isForMainFrame,
               let url = navigationResponse.response.url,
               shouldBlockInsecureHTTPSubframeDownload?(url) == true {
                #if DEBUG
                cmuxDebugLog("download.policy=cancel reason=insecureHTTPSubframe url=\(url.absoluteString)")
                #endif
                decisionHandler(.cancel)
                return
            }
            #if DEBUG
            cmuxDebugLog("download.policy=download reason=\(reason) mime=\(mime) mainFrame=\(navigationResponse.isForMainFrame ? 1 : 0)")
            #endif
            if navigationResponse.isForMainFrame {
                // A main-frame response follows didStartProvisionalNavigation, so this is the
                // exact WKNavigation whose response WebKit is converting into a download.
                didChooseMainFrameDownloadPolicy?(webView, activeMainFrameNavigation)
            }
            decisionHandler(.download)
            return
        }

        subframeDownloadIntents.markRenderedSubframePDFIfNeeded(
            responseURL: navigationResponse.response.url,
            mimeType: mime,
            isForMainFrame: navigationResponse.isForMainFrame
        )
        if isPDFMIMEType(mime), let url = navigationResponse.response.url {
            didRenderPDFDocument?(url, navigationResponse.isForMainFrame)
        } else if navigationResponse.isForMainFrame {
            didClearPDFDocument?()
        }
        decisionHandler(.allow)
    }

    func recordSubframeDownloadIntent(_ url: URL) {
        subframeDownloadIntents.record(url)
    }

    /// Replaces a disallowed document with the localized policy explanation.
    /// The caller has already cancelled WebKit's navigation decision.
    func blockURLAllowlistNavigation(_ url: URL, in webView: WKWebView) {
        clearAttemptedRequest(discardPendingBypasses: true)
        activePolicyBlockedURL = url
        if let handleBlockedURLAllowlistNavigation {
            handleBlockedURLAllowlistNavigation(url, webView)
        } else {
            BrowserURLAllowlistBlockedPage(
                blockedURL: url,
                isManaged: BrowserURLAllowlistPolicy(defaults: .standard).isManaged
            ).load(in: webView)
        }
    }

    private func trustedInternalNavigation(for url: URL, in webView: WKWebView) -> Bool {
        if trustedInternalNavigationURL?.absoluteString == url.absoluteString {
            return true
        }
        guard let cmuxWebView = webView as? CmuxWebView,
              cmuxWebView.consumeTrustedInternalNavigation(url) else {
            return false
        }
        trustedInternalNavigationURL = url
        return true
    }

    /// Applies a newly changed policy to the currently displayed document.
    func enforceURLAllowlistPolicy(in webView: WKWebView, displayURL: URL? = nil) {
        guard let url = displayURL ?? webView.url else { return }
        if artifactHTMLPreviewPolicy?.allowsNavigation(
            to: url,
            targetIsMainFrame: true
        ) == true {
            return
        }
        guard !BrowserURLAllowlistPolicy(defaults: .standard).allows(url) else {
            return
        }
        blockURLAllowlistNavigation(url, in: webView)
    }

    func recordPDFPrintIntent(_ url: URL) {
        subframeDownloadIntents.recordPDFPrintIntent(url)
    }

    func recordPDFPrintIntentIfNeeded(_ request: URLRequest, sourceFrame: WKFrameInfo?) {
        guard let url = request.url else { return }
        subframeDownloadIntents.recordPDFPrintIntent(
            url,
            sourceFrameURL: sourceFrame?.request.url,
            sourceIsMainFrame: sourceFrame?.isMainFrame ?? true
        )
    }

    private func isPDFMIMEType(_ mimeType: String?) -> Bool {
        mimeType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("application/pdf") == .orderedSame
    }

    private func clearActiveMainFrameNavigation(ifMatching navigation: WKNavigation?) {
        guard activeMainFrameNavigation === navigation else { return }
        activeMainFrameNavigation = nil
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let restoreAttemptID = isMainFrame ? pendingMainFrameDownloadRestoreAttemptID : nil
        #if DEBUG
        cmuxDebugLog("download.didBecome source=navigationAction")
        #endif
        NSLog("BrowserPanel download didBecome from navigationAction")
        didBecomeDownload?(webView, isMainFrame, restoreAttemptID)
        if isMainFrame { pendingMainFrameDownloadRestoreAttemptID = nil }
        download.delegate = downloadDelegate
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let restoreAttemptID = navigationResponse.isForMainFrame ? pendingMainFrameDownloadRestoreAttemptID : nil
        #if DEBUG
        cmuxDebugLog("download.didBecome source=navigationResponse")
        #endif
        NSLog("BrowserPanel download didBecome from navigationResponse")
        didBecomeDownload?(webView, navigationResponse.isForMainFrame, restoreAttemptID)
        if navigationResponse.isForMainFrame { pendingMainFrameDownloadRestoreAttemptID = nil }
        download.delegate = downloadDelegate
    }
}
