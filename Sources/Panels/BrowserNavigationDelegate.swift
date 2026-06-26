import AppKit
import Foundation
import WebKit

@MainActor final class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    private let subframeDownloadIntents = BrowserSubframeDownloadIntentTracker()
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
    private let basicAuthPromptCoordinator = BrowserHTTPBasicAuthPromptCoordinator()

    func cancelPendingHTTPBasicAuthPrompts(allowFuturePrompts: Bool = false) {
        basicAuthPromptCoordinator.cancelAll(allowFuturePrompts: allowFuturePrompts)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastAttemptedURL = lastAttemptedURL ?? webView.url
        didStartProvisionalNavigation?(webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
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
        loadErrorPage(in: webView, failedURL: failedURL, error: nsError)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
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

        // WKWebView rejects all authentication challenges by default when this
        // delegate method is not implemented (.rejectProtectionSpace). This
        // breaks TLS client-certificate flows such as Microsoft Entra ID
        // Conditional Access, which verifies device compliance via a client
        // certificate stored in the system keychain by MDM enrollment.
        //
        // By returning .performDefaultHandling the system's standard URL-loading
        // behaviour takes over: the keychain is searched for matching client
        // identities, MDM-installed root CAs are trusted, and any configured SSO
        // extensions (e.g. Microsoft Enterprise SSO) can intercept the challenge.
        completionHandler(.performDefaultHandling, nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
#if DEBUG
        cmuxDebugLog("browser.webcontent.terminated panel=\(String(describing: self))")
#endif
        didTerminateWebContentProcess?(webView)
    }

    private func loadErrorPage(in webView: WKWebView, failedURL: String, error: NSError) {
        let title: String
        let message: String

        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorTimedOut):
            title = String(localized: "browser.error.cantReach.title", defaultValue: "Can\u{2019}t reach this page")
            if failedURL.isEmpty {
                message = String(localized: "browser.error.cantReach.messageSite", defaultValue: "The site refused to connect. Check that a server is running on this address.")
            } else {
                message = String(localized: "browser.error.cantReach.messageURL", defaultValue: "\(failedURL) refused to connect. Check that a server is running on this address.")
            }
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            title = String(localized: "browser.error.noInternet", defaultValue: "No internet connection")
            message = String(localized: "browser.error.checkNetwork", defaultValue: "Check your network connection and try again.")
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
             (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid):
            title = String(localized: "browser.error.insecure.title", defaultValue: "Connection isn\u{2019}t secure")
            message = String(localized: "browser.error.invalidCertificate", defaultValue: "The certificate for this site is invalid.")
        default:
            title = String(localized: "browser.error.cantOpen.title", defaultValue: "Can\u{2019}t open this page")
            message = error.localizedDescription
        }

        let escapeHTML: (String) -> String = { value in
            value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }

        let escapedTitle = escapeHTML(title)
        let escapedMessage = escapeHTML(message)
        let escapedURL = escapeHTML(failedURL)
        let escapedReloadLabel = escapeHTML(String(localized: "browser.error.reload", defaultValue: "Reload"))

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width">
        <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            display: flex; align-items: center; justify-content: center;
            min-height: 80vh; margin: 0; padding: 20px;
            background: #1a1a1a; color: #e0e0e0;
        }
        .container { text-align: center; max-width: 420px; }
        h1 { font-size: 18px; font-weight: 600; margin-bottom: 8px; }
        p { font-size: 13px; color: #999; line-height: 1.5; }
        .url { font-size: 12px; color: #666; word-break: break-all; margin-top: 16px; }
        button {
            margin-top: 20px; padding: 6px 20px;
            background: #333; color: #e0e0e0; border: 1px solid #555;
            border-radius: 6px; font-size: 13px; cursor: pointer;
        }
        button:hover { background: #444; }
        @media (prefers-color-scheme: light) {
            body { background: #fafafa; color: #222; }
            p { color: #666; }
            .url { color: #999; }
            button { background: #eee; color: #222; border-color: #ccc; }
            button:hover { background: #ddd; }
        }
        </style>
        </head>
        <body>
        <div class="container">
            <h1>\(escapedTitle)</h1>
            <p>\(escapedMessage)</p>
            <div class="url">\(escapedURL)</div>
            <button onclick="location.reload()">\(escapedReloadLabel)</button>
        </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: failedURL))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
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
        subframeDownloadIntents.updateIfNeeded(navigationAction)
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
            openRequestInNewTab(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

#if DEBUG
        let targetURL = navigationAction.request.url?.absoluteString ?? "nil"
        cmuxDebugLog("browser.nav.decidePolicy.action kind=allow url=\(targetURL)")
#endif
        if navigationAction.targetFrame?.isMainFrame != false {
            lastAttemptedURL = navigationAction.request.url
        }
        decisionHandler(.allow)
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
        let allowsSubframeDownload = navigationResponse.isForMainFrame
            || subframeDownloadIntents.consume(for: navigationResponse.response.url)
        if !navigationResponse.isForMainFrame,
           allowsSubframeDownload,
           let url = navigationResponse.response.url,
           shouldBlockInsecureHTTPNavigation?(url) == true {
            #if DEBUG
            cmuxDebugLog("download.policy=cancel reason=insecureHTTPSubframe url=\(url.absoluteString)")
            #endif
            decisionHandler(.cancel)
            return
        }
        if let reason = BrowserDownloadFilenameResolver().navigationResponseDownloadReason(
            mimeType: mime,
            canShowMIMEType: canShow,
            contentDisposition: contentDisposition,
            isForMainFrame: navigationResponse.isForMainFrame,
            allowsSubframeDownload: allowsSubframeDownload
        ) {
            #if DEBUG
            cmuxDebugLog("download.policy=download reason=\(reason) mime=\(mime) mainFrame=\(navigationResponse.isForMainFrame ? 1 : 0)")
            #endif
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    func recordSubframeDownloadIntent(_ url: URL) {
        subframeDownloadIntents.record(url)
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
