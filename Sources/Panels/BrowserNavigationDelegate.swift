import AppKit
import Foundation
import WebKit

@MainActor final class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    private let subframeDownloadIntents = BrowserSubframeDownloadIntentTracker()
    private var shouldPrintAfterCurrentNavigationFinishes = false
    var didStartProvisionalNavigation: ((WKWebView) -> Void)?
    var didCommit: ((WKWebView) -> Void)?
    var didFinish: ((WKWebView) -> Void)?
    var didFailNavigation: ((WKWebView, String, WKNavigation?) -> Void)?
    var didCancelProvisionalNavigation: ((WKWebView, WKNavigation?) -> Void)?
    var didBecomeDownload: ((WKWebView, Bool) -> Void)?
    var didTerminateWebContentProcess: ((WKWebView) -> Void)?
    var openInNewTab: ((URL) -> Void)?
    var requestNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    var presentAlert: BrowserAlertPresenter = browserPresentAlert
    var shouldBlockInsecureHTTPNavigation: ((URL) -> Bool)?
    var shouldBlockInsecureHTTPSubframeDownload: ((URL) -> Bool)?
    var handleBlockedInsecureHTTPNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    var didRenderPDFDocument: ((URL, Bool) -> Void)?
    var didClearPDFDocument: (() -> Void)?
    /// Direct reference to the download delegate - must be set synchronously in didBecome callbacks.
    var downloadDelegate: WKDownloadDelegate?
    /// The URL of the last navigation that was attempted. Used to preserve the omnibar URL
    /// when a provisional navigation fails (e.g. connection refused on localhost:3000).
    var lastAttemptedURL: URL?
    private(set) var activeErrorPageDisplayURL: URL?
    private let basicAuthPromptCoordinator = BrowserHTTPBasicAuthPromptCoordinator()
    private let clientCertificateAuthenticationController = BrowserClientCertificateAuthenticationController()
    private let sslBypassState = BrowserSSLTrustBypassState()
    private var lastAttemptedRequest: URLRequest?
    private var lastAttemptedRequestWasDiscardedForReplay = false
    private var acceptsSSLTrustBypassMessages = false
    private var activeSSLTrustBypassErrorPageFailedURL: String?
    private var activeSSLTrustBypassReplayRequest: URLRequest?
    private var activeSSLTrustBypassErrorPageRetryRequest: URLRequest?

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
        lastAttemptedRequest = nil
        lastAttemptedRequestWasDiscardedForReplay = false
        lastAttemptedURL = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastAttemptedURL = lastAttemptedURL ?? webView.url ?? lastAttemptedRequest?.url
        shouldPrintAfterCurrentNavigationFinishes = false
        didClearPDFDocument?()
        didStartProvisionalNavigation?(webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if activeSSLTrustBypassReplayRequest != nil || activeSSLTrustBypassErrorPageRetryRequest != nil {
            clearAttemptedRequest(discardPendingBypasses: true)
        }
        didCommit?(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish?(webView)
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
        didFailNavigation?(webView, failedURL, navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        NSLog("BrowserPanel provisional navigation failed: %@", error.localizedDescription)

        // Cancelled navigations (e.g. rapid typing) are not real errors.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            didCancelProvisionalNavigation?(webView, navigation)
            return
        }

        // "Frame load interrupted" (WebKitErrorDomain code 102) fires when a
        // navigation response is converted into a download via .download policy.
        // This is expected and should not show an error page.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            didCancelProvisionalNavigation?(webView, navigation)
            return
        }

        let failedURL = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            ?? lastAttemptedURL?.absoluteString
            ?? ""
        didFailNavigation?(webView, failedURL, navigation)
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
            startPrompt: { [presentAlert] finishPrompt, registerCancelPrompt in
                browserHandleHTTPBasicAuthenticationChallenge(
                    in: webView,
                    challenge: challenge,
                    presentAlert: presentAlert,
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
            presentAlert: presentAlert,
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
        if let url = navigationAction.request.url,
           url.scheme == "cmux-browser-action",
           url.host == "bypass-ssl" {
            decisionHandler(.cancel)
            handleSSLTrustBypassAction(url, in: webView)
            return
        }

        let openRequestInNewTab: (URLRequest) -> Void = { [requestNavigation, openInNewTab] request in
            if let requestNavigation {
                requestNavigation(request, .newTab)
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

        if let url = navigationAction.request.url,
           shouldOpenCheckoutInSystemBrowser(navigationAction, url: url) {
            clearAttemptedRequest(discardPendingBypasses: true)
            let opened = NSWorkspace.shared.open(url)
#if DEBUG
            cmuxDebugLog(
                "browser.nav.decidePolicy.action kind=openCheckoutInSystemBrowser opened=\(opened ? 1 : 0) " +
                "url=\(browserNavigationDebugURL(url))"
            )
#endif
            decisionHandler(opened ? .cancel : .allow)
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

        // WebKit cannot open app-specific deeplinks (discord://, slack://, zoommtg://, etc.).
        // Hand these off to macOS so the owning app can handle them.
        if let url = navigationAction.request.url,
           browserShouldRouteExternalNavigation(url) {
            clearAttemptedRequest(discardPendingBypasses: true)
            browserHandleExternalNavigation(
                url,
                source: "navDelegate",
                webView: webView,
                loadFallbackRequest: { [requestNavigation] request in
                    requestNavigation?(request, .currentTab)
                },
                presentAlert: presentAlert
            )
            decisionHandler(.cancel)
            return
        }

        if navigationAction.shouldPerformDownload {
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
            openRequestInNewTab(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

        // target=_blank link navigations should open in a new tab.
        // Scripted popups (navigationType == .other) are handled in
        // WKUIDelegate.createWebViewWith so OAuth opener linkage survives.
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
            openRequestInNewTab(navigationAction.request)
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
        decisionHandler(.allow)
    }

    private func shouldOpenCheckoutInSystemBrowser(_ navigationAction: WKNavigationAction, url: URL) -> Bool {
        guard navigationAction.targetFrame?.isMainFrame != false else { return false }
        guard navigationAction.navigationType == .linkActivated else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard url.path == "/api/billing/checkout",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: {
                  $0.name == "cmux_external_browser" && $0.value != "0"
              }) == true else {
            return false
        }
        return true
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
        let mime = navigationResponse.response.mimeType ?? "unknown"
        let canShow = navigationResponse.canShowMIMEType

        // Only classify HTTP(S) responses as downloads. Subframes are eligible
        // only for explicit attachment/force-download MIME decisions; the
        // resolver keeps cannot-show MIME fallback scoped to main-frame loads.
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

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        #if DEBUG
        cmuxDebugLog("download.didBecome source=navigationAction")
        #endif
        NSLog("BrowserPanel download didBecome from navigationAction")
        didBecomeDownload?(webView, navigationAction.targetFrame?.isMainFrame ?? true)
        download.delegate = downloadDelegate
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        #if DEBUG
        cmuxDebugLog("download.didBecome source=navigationResponse")
        #endif
        NSLog("BrowserPanel download didBecome from navigationResponse")
        didBecomeDownload?(webView, navigationResponse.isForMainFrame)
        download.delegate = downloadDelegate
    }
}

extension WKWebView {
    @MainActor
    func cmuxRunPrintOperation() {
        guard #available(macOS 11.0, *) else { return }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let operation = printOperation(with: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
