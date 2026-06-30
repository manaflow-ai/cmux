import AppKit
import Foundation
import WebKit

@MainActor final class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    var didStartProvisionalNavigation: ((WKWebView) -> Void)?
    var didCommit: ((WKWebView) -> Void)?
    var didFinish: ((WKWebView) -> Void)?
    var didFailNavigation: ((WKWebView, String) -> Void)?
    var didCancelProvisionalNavigation: ((WKWebView) -> Void)?
    var didTerminateWebContentProcess: ((WKWebView) -> Void)?
    var openInNewTab: ((URL) -> Void)?
    var requestNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    var presentAlert: BrowserAlertPresenter = browserPresentAlert
    var shouldBlockInsecureHTTPNavigation: ((URL) -> Bool)?
    var handleBlockedInsecureHTTPNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
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
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("BrowserPanel navigation failed: %@", error.localizedDescription)
        // Treat committed-navigation failures the same as provisional ones so
        // stale favicon/title state from the prior page gets cleared.
        let failedURL = webView.url?.absoluteString ?? ""
        didFailNavigation?(webView, failedURL)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        NSLog("BrowserPanel provisional navigation failed: %@", error.localizedDescription)

        // Cancelled navigations (e.g. rapid typing) are not real errors.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            didCancelProvisionalNavigation?(webView)
            return
        }

        // "Frame load interrupted" (WebKitErrorDomain code 102) fires when a
        // navigation response is converted into a download via .download policy.
        // This is expected and should not show an error page.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            didCancelProvisionalNavigation?(webView)
            return
        }

        let failedURL = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            ?? lastAttemptedURL?.absoluteString
            ?? ""
        didFailNavigation?(webView, failedURL)
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

        if BrowserNavigationModifierBypassPolicy().shouldOpenInDefaultBrowser(navigationType: navigationAction.navigationType, modifierFlags: navigationAction.modifierFlags, buttonNumber: navigationAction.buttonNumber, hasRecentMiddleClickIntent: hasRecentMiddleClickIntent),
           let url = navigationAction.request.url {
#if DEBUG
            cmuxDebugLog("browser.nav.decidePolicy.action kind=openDefaultBrowserModifierBypass url=\(browserNavigationDebugURL(url))")
#endif
            clearAttemptedRequest(discardPendingBypasses: true)
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
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
        if !navigationResponse.isForMainFrame {
            decisionHandler(.allow)
            return
        }

        let mime = navigationResponse.response.mimeType ?? "unknown"
        let canShow = navigationResponse.canShowMIMEType
        let responseURL = navigationResponse.response.url?.absoluteString ?? "nil"

        // Only classify HTTP(S) top-level responses as downloads.
        if let scheme = navigationResponse.response.url?.scheme?.lowercased(),
           scheme != "http", scheme != "https" {
            decisionHandler(.allow)
            return
        }

        NSLog("BrowserPanel navigationResponse: url=%@ mime=%@ canShow=%d isMainFrame=%d",
              responseURL, mime, canShow ? 1 : 0,
              navigationResponse.isForMainFrame ? 1 : 0)

        let contentDisposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        if let reason = BrowserDownloadFilenameResolver().navigationResponseDownloadReason(
            mimeType: mime,
            canShowMIMEType: canShow,
            contentDisposition: contentDisposition
        ) {
            NSLog("BrowserPanel download: %@ mime=%@ url=%@", reason, mime, responseURL)
            #if DEBUG
            cmuxDebugLog("download.policy=download reason=\(reason) mime=\(mime)")
            #endif
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        #if DEBUG
        cmuxDebugLog("download.didBecome source=navigationAction")
        #endif
        NSLog("BrowserPanel download didBecome from navigationAction")
        download.delegate = downloadDelegate
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        #if DEBUG
        cmuxDebugLog("download.didBecome source=navigationResponse")
        #endif
        NSLog("BrowserPanel download didBecome from navigationResponse")
        download.delegate = downloadDelegate
    }
}
