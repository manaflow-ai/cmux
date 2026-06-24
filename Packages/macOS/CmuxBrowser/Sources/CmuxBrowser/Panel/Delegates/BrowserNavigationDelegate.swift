public import WebKit
public import Foundation
internal import AppKit
internal import os

/// `WKNavigationDelegate` for an embedded browser panel's `WKWebView`.
///
/// Lifted byte-faithfully out of the app target's `BrowserPanel`. Every panel
/// callback the original delegate reached back into the panel for is now an
/// injected closure (``openInNewTab``, ``requestNavigation``,
/// ``shouldBlockInsecureHTTPNavigation``, ``handleBlockedInsecureHTTPNavigation``,
/// the navigation-lifecycle hooks, and ``didTerminateWebContentProcess``); the
/// owning `BrowserPanel` sets them at construction. External-scheme routing,
/// fallback loads, and alert presentation go through the injected
/// ``BrowserExternalNavigationPresenter``. The former `#if DEBUG`-guarded
/// `cmuxDebugLog` traces are surfaced through the injected ``logSink`` (mirroring
/// `BrowserDownloadDelegate.logSink`), and the production failure logging that
/// used `NSLog` now goes through a file-scoped `os.Logger`.
///
/// `@MainActor`: every member touches main-thread-only WebKit/AppKit state
/// (`WKWebView`, `NSApp.currentEvent`, the alert presenter) and is only ever
/// invoked on WebKit's main-thread delegate callbacks, matching the original
/// app-target behavior.
@MainActor
public final class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    /// Popup/new-tab routing policy shared with the UI delegate.
    public let navigationPolicy = BrowserPopupNavigationPolicy()

    /// Routes external-scheme navigations, in-page fallback loads, and alert
    /// presentation. Injected so the localized alert copy resolves against the
    /// app catalog.
    public let externalNavigationPresenter: BrowserExternalNavigationPresenter

    /// Reports whether `webView` had a recent middle-click intent, used to bias
    /// new-tab routing. Injected because the underlying tracking lives in the
    /// app target's `CmuxWebView`; defaults to always-false.
    public var hasRecentMiddleClickIntent: @MainActor (WKWebView) -> Bool

    /// Invoked when the web view starts a provisional navigation.
    public var didStartProvisionalNavigation: ((WKWebView) -> Void)?
    /// Invoked when the web view commits a navigation.
    public var didCommit: ((WKWebView) -> Void)?
    /// Invoked when the web view finishes a navigation.
    public var didFinish: ((WKWebView) -> Void)?
    /// Invoked when a navigation fails, with the failed URL string.
    public var didFailNavigation: ((WKWebView, String) -> Void)?
    /// Invoked when a provisional navigation is cancelled (rapid typing, download
    /// conversion) rather than failing for real.
    public var didCancelProvisionalNavigation: ((WKWebView) -> Void)?
    /// Invoked when the web content process terminates.
    public var didTerminateWebContentProcess: ((WKWebView) -> Void)?
    /// Opens `url` in a new tab.
    public var openInNewTab: ((URL) -> Void)?
    /// Requests a navigation for `request` with the given tab intent.
    public var requestNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    /// Presents an alert for `webView`. Defaults to the external-navigation
    /// presenter's sheet/modal presentation.
    public var presentAlert: BrowserExternalNavigationPresenter.AlertPresenter
    /// Returns whether a main-frame navigation to `url` is a blocked insecure
    /// HTTP navigation.
    public var shouldBlockInsecureHTTPNavigation: ((URL) -> Bool)?
    /// Handles a blocked insecure-HTTP navigation for `request` with the given
    /// tab intent.
    public var handleBlockedInsecureHTTPNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    /// Direct reference to the download delegate — must be set synchronously in
    /// didBecome callbacks.
    public weak var downloadDelegate: WKDownloadDelegate?
    /// The URL of the last navigation that was attempted. Used to preserve the
    /// omnibar URL when a provisional navigation fails (e.g. connection refused
    /// on localhost:3000).
    public var lastAttemptedURL: URL?

    /// Optional debug-log sink, invoked with the former `#if DEBUG`-guarded
    /// `cmuxDebugLog` trace messages. `nil` in release builds so the traces are
    /// compiled out at the wiring site, exactly as before.
    public var logSink: (@MainActor @Sendable (String) -> Void)?

    /// Creates a navigation delegate. Callers assign the closure properties after
    /// construction.
    ///
    /// - Parameters:
    ///   - externalNavigationPresenter: Routes external-scheme navigation,
    ///     in-page fallback loads, and alert presentation.
    ///   - hasRecentMiddleClickIntent: Reports whether a web view had a recent
    ///     middle-click intent (defaults to always-false).
    public init(
        externalNavigationPresenter: BrowserExternalNavigationPresenter,
        hasRecentMiddleClickIntent: @escaping @MainActor (WKWebView) -> Bool = { _ in false }
    ) {
        self.externalNavigationPresenter = externalNavigationPresenter
        self.hasRecentMiddleClickIntent = hasRecentMiddleClickIntent
        self.presentAlert = { alert, webView, completion, cancel in
            externalNavigationPresenter.presentAlert(alert, in: webView, completion: completion, cancel: cancel)
        }
        super.init()
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastAttemptedURL = lastAttemptedURL ?? webView.url
        didStartProvisionalNavigation?(webView)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        didCommit?(webView)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish?(webView)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.logger.error("BrowserPanel navigation failed: \(error.localizedDescription, privacy: .public)")
        // Treat committed-navigation failures the same as provisional ones so
        // stale favicon/title state from the prior page gets cleared.
        let failedURL = webView.url?.absoluteString ?? ""
        didFailNavigation?(webView, failedURL)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        Self.logger.error("BrowserPanel provisional navigation failed: \(error.localizedDescription, privacy: .public)")

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

    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
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

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
#if DEBUG
        logSink?("browser.webcontent.terminated panel=\(String(describing: self))")
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

    public func webView(
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
        let hasRecentMiddleClickIntent = self.hasRecentMiddleClickIntent(webView)
        let shouldOpenInNewTab = navigationPolicy.shouldOpenInNewTab(
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
        let requestURL = navigationPolicy.debugURL(navigationAction.request.url)
        let targetMainFrame = navigationAction.targetFrame.map { $0.isMainFrame ? "1" : "0" } ?? "nil"
        logSink?(
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
            logSink?(
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
           externalNavigationPresenter.resolver.shouldRouteExternalNavigation(url) {
            externalNavigationPresenter.handleExternalNavigation(
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
            logSink?(
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
           navigationPolicy.shouldFallbackNilTargetToNewTab(
               navigationType: navigationAction.navigationType
           ),
           let requestURL = navigationAction.request.url {
#if DEBUG
            logSink?(
                "browser.nav.decidePolicy.action kind=openInNewTabFromNilTarget url=\(requestURL.absoluteString)"
            )
#endif
            openRequestInNewTab(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

#if DEBUG
        let targetURL = navigationAction.request.url?.absoluteString ?? "nil"
        logSink?("browser.nav.decidePolicy.action kind=allow url=\(targetURL)")
#endif
        if navigationAction.targetFrame?.isMainFrame != false {
            lastAttemptedURL = navigationAction.request.url
        }
        decisionHandler(.allow)
    }

    public func webView(
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

        Self.logger.log("BrowserPanel navigationResponse: url=\(responseURL, privacy: .public) mime=\(mime, privacy: .public) canShow=\(canShow ? 1 : 0) isMainFrame=\(navigationResponse.isForMainFrame ? 1 : 0)")

        let contentDisposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        if let reason = BrowserDownloadFilenameResolver().navigationResponseDownloadReason(
            mimeType: mime,
            canShowMIMEType: canShow,
            contentDisposition: contentDisposition
        ) {
            Self.logger.log("BrowserPanel download: \(reason, privacy: .public) mime=\(mime, privacy: .public) url=\(responseURL, privacy: .public)")
            #if DEBUG
            logSink?("download.policy=download reason=\(reason) mime=\(mime)")
            #endif
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        #if DEBUG
        logSink?("download.didBecome source=navigationAction")
        #endif
        Self.logger.log("BrowserPanel download didBecome from navigationAction")
        download.delegate = downloadDelegate
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        #if DEBUG
        logSink?("download.didBecome source=navigationResponse")
        #endif
        Self.logger.log("BrowserPanel download didBecome from navigationResponse")
        download.delegate = downloadDelegate
    }

    /// Logger for production navigation/download diagnostics (replaces the
    /// former `NSLog` calls).
    private static let logger = Logger(subsystem: "com.cmux.browser", category: "BrowserNavigationDelegate")
}
