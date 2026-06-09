import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif

extension WKWebView {
    func cmuxInspectorObject() -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard responds(to: selector),
              let inspector = perform(selector)?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        return inspector
    }

    func cmuxInspectorFrontendWebView() -> WKWebView? {
        guard let inspector = cmuxInspectorObject() else { return nil }
        let selector = NSSelectorFromString("inspectorWebView")
        guard inspector.responds(to: selector),
              let inspectorWebView = inspector.perform(selector)?.takeUnretainedValue() as? WKWebView else {
            return nil
        }
        return inspectorWebView
    }
}

@MainActor
enum WebViewInspectorTeardown {
    @discardableResult
    static func closeAllInspectors(in window: NSWindow) -> Int {
        assert(Thread.isMainThread)

        return webViews(in: window).reduce(0) { count, webView in
            closeInspector(for: webView) ? count + 1 : count
        }
    }

    @discardableResult
    static func closeAllInspectors(in windows: [NSWindow]) -> Int {
        windows.reduce(0) { count, window in
            count + closeAllInspectors(in: window)
        }
    }

    @discardableResult
    static func closeInspector(for webView: WKWebView) -> Bool {
        assert(Thread.isMainThread)

        guard !isInspectorFrontendWebView(webView),
              let inspector = webView.cmuxInspectorObject() else {
            return false
        }

        let isVisibleSelector = NSSelectorFromString("isVisible")
        let isAttachedSelector = NSSelectorFromString("isAttached")
        let isVisible = inspector.cmuxCallBool(selector: isVisibleSelector)
        let isAttached = inspector.cmuxCallBool(selector: isAttachedSelector)
        let shouldClose = (isVisible == true)
            || (isAttached == true)
            || (isVisible == nil && isAttached == nil)
        guard shouldClose else { return false }

        // cmux already opens Web Inspector through WebKit's `_inspector` object
        // because the deployable SDK surface does not expose a stable close API.
        // Keep teardown on the same auditable SPI path so WebKit unregisters the
        // inspector window observers before the parent AppKit close cascade runs.
        let closeSelector = NSSelectorFromString("close")
        guard inspector.responds(to: closeSelector) else { return false }
        inspector.cmuxCallVoid(selector: closeSelector)
        return true
    }

    private static func webViews(in window: NSWindow) -> [WKWebView] {
        var seen = Set<ObjectIdentifier>()
        var result: [WKWebView] = []
        let roots = [window.contentView, window.contentView?.superview].compactMap { $0 }
        for root in roots {
            collectWebViews(in: root, seen: &seen, result: &result)
        }
        return result
    }

    private static func collectWebViews(
        in view: NSView,
        seen: inout Set<ObjectIdentifier>,
        result: inout [WKWebView]
    ) {
        if let webView = view as? WKWebView,
           !isInspectorFrontendWebView(webView) {
            let id = ObjectIdentifier(webView)
            if !seen.contains(id) {
                seen.insert(id)
                result.append(webView)
            }
        }

        for subview in view.subviews {
            collectWebViews(in: subview, seen: &seen, result: &result)
        }
    }

    private static func isInspectorFrontendWebView(_ webView: WKWebView) -> Bool {
        cmuxIsWebInspectorObject(webView)
    }
}

extension NSObject {
    func cmuxCallBool(selector: Selector) -> Bool? {
        guard responds(to: selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        return fn(self, selector)
    }

    func cmuxCallVoid(selector: Selector) {
        guard responds(to: selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
    }
}

// MARK: - Download Delegate

/// Handles WKDownload lifecycle by saving to a temp file synchronously (no UI
/// during WebKit callbacks), then showing NSSavePanel after the download finishes.
class BrowserDownloadDelegate: NSObject, WKDownloadDelegate {
    private struct DownloadState {
        let tempURL: URL
        let suggestedFilename: String
    }

    /// Tracks active downloads keyed by WKDownload identity.
    private var activeDownloads: [ObjectIdentifier: DownloadState] = [:]
    private let activeDownloadsLock = NSLock()
    var onDownloadStarted: ((String) -> Void)?
    var onDownloadReadyToSave: (() -> Void)?
    var onDownloadFailed: ((Error) -> Void)?

    private static let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func sanitizedFilename(_ raw: String, fallbackURL: URL?) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (trimmed as NSString).lastPathComponent
        let fromURL = fallbackURL?.lastPathComponent ?? ""
        let base = candidate.isEmpty ? fromURL : candidate
        let replaced = base.replacingOccurrences(of: ":", with: "-")
        let safe = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "download" : safe
    }

    private func storeState(_ state: DownloadState, for download: WKDownload) {
        activeDownloadsLock.lock()
        activeDownloads[ObjectIdentifier(download)] = state
        activeDownloadsLock.unlock()
    }

    private func removeState(for download: WKDownload) -> DownloadState? {
        activeDownloadsLock.lock()
        let state = activeDownloads.removeValue(forKey: ObjectIdentifier(download))
        activeDownloadsLock.unlock()
        return state
    }

    private func notifyOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        // Save to a temp file — return synchronously so WebKit is never blocked.
        let safeFilename = Self.sanitizedFilename(suggestedFilename, fallbackURL: response.url)
        let tempFilename = "\(UUID().uuidString)-\(safeFilename)"
        let destURL = Self.tempDir.appendingPathComponent(tempFilename, isDirectory: false)
        try? FileManager.default.removeItem(at: destURL)
        storeState(DownloadState(tempURL: destURL, suggestedFilename: safeFilename), for: download)
        notifyOnMain { [weak self] in
            self?.onDownloadStarted?(safeFilename)
        }
        #if DEBUG
        cmuxDebugLog("download.decideDestination file=\(safeFilename)")
        #endif
        NSLog("BrowserPanel download: temp path=%@", destURL.path)
        completionHandler(destURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let info = removeState(for: download) else {
            #if DEBUG
            cmuxDebugLog("download.finished missing-state")
            #endif
            return
        }
        #if DEBUG
        cmuxDebugLog("download.finished file=\(info.suggestedFilename)")
        #endif
        NSLog("BrowserPanel download finished: %@", info.suggestedFilename)

        // Show NSSavePanel on the next runloop iteration (safe context).
        DispatchQueue.main.async {
            self.onDownloadReadyToSave?()
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = info.suggestedFilename
            savePanel.canCreateDirectories = true
            savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

            savePanel.begin { result in
                guard result == .OK, let destURL = savePanel.url else {
                    try? FileManager.default.removeItem(at: info.tempURL)
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.moveItem(at: info.tempURL, to: destURL)
                    NSLog("BrowserPanel download saved: %@", destURL.path)
                } catch {
                    NSLog("BrowserPanel download move failed: %@", error.localizedDescription)
                    try? FileManager.default.removeItem(at: info.tempURL)
                }
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let info = removeState(for: download) {
            try? FileManager.default.removeItem(at: info.tempURL)
        }
        notifyOnMain { [weak self] in
            self?.onDownloadFailed?(error)
        }
        #if DEBUG
        cmuxDebugLog("download.failed error=\(error.localizedDescription)")
        #endif
        NSLog("BrowserPanel download failed: %@", error.localizedDescription)
    }
}

// MARK: - Navigation Delegate

func browserNavigationShouldOpenInNewTab(
    navigationType: WKNavigationType,
    modifierFlags: NSEvent.ModifierFlags,
    buttonNumber: Int,
    hasRecentMiddleClickIntent: Bool = false,
    currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type,
    currentEventButtonNumber: Int? = NSApp.currentEvent?.buttonNumber
) -> Bool {
    guard navigationType == .linkActivated || navigationType == .other else {
        return false
    }

    if modifierFlags.contains(.command) {
        return true
    }
    if buttonNumber == 2 {
        return true
    }
    // In some WebKit paths, middle-click arrives as buttonNumber=4.
    // Recover intent when we just observed a local middle-click.
    if buttonNumber == 4, hasRecentMiddleClickIntent {
        return true
    }

    // WebKit can omit buttonNumber for middle-click link activations.
    if let currentEventType,
       (currentEventType == .otherMouseDown || currentEventType == .otherMouseUp),
       currentEventButtonNumber == 2 {
        return true
    }
    return false
}

func browserNavigationShouldCreatePopup(
    navigationType: WKNavigationType,
    modifierFlags: NSEvent.ModifierFlags,
    buttonNumber: Int,
    popupFeaturesWereSpecified: Bool = false,
    hasRecentMiddleClickIntent: Bool = false,
    currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type,
    currentEventButtonNumber: Int? = NSApp.currentEvent?.buttonNumber
) -> Bool {
    let isUserNewTab = browserNavigationShouldOpenInNewTab(
        navigationType: navigationType,
        modifierFlags: modifierFlags,
        buttonNumber: buttonNumber,
        hasRecentMiddleClickIntent: hasRecentMiddleClickIntent,
        currentEventType: currentEventType,
        currentEventButtonNumber: currentEventButtonNumber
    )
    return navigationType == .other && popupFeaturesWereSpecified && !isUserNewTab
}

func browserNavigationShouldFallbackNilTargetToNewTab(
    navigationType: WKNavigationType
) -> Bool {
    // Scripted popups rely on WKUIDelegate.createWebViewWith returning a live
    // web view so window.opener/postMessage remain intact across OAuth flows.
    navigationType != .other
}

func browserNavigationHasSimpleUserActivation(
    currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type
) -> Bool {
    switch currentEventType {
    case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp:
        return true
    default:
        return false
    }
}

func browserNavigationPopupFeaturesWereSpecified(
    x: NSNumber?,
    y: NSNumber?,
    width: NSNumber?,
    height: NSNumber?,
    menuBarVisibility: NSNumber?,
    statusBarVisibility: NSNumber?,
    toolbarsVisibility: NSNumber?,
    allowsResizing: NSNumber?
) -> Bool {
    x != nil ||
        y != nil ||
        width != nil ||
        height != nil ||
        menuBarVisibility != nil ||
        statusBarVisibility != nil ||
        toolbarsVisibility != nil ||
        allowsResizing != nil
}

func browserNavigationPopupFeaturesWereSpecified(windowFeatures: WKWindowFeatures) -> Bool {
    browserNavigationPopupFeaturesWereSpecified(
        x: windowFeatures.x,
        y: windowFeatures.y,
        width: windowFeatures.width,
        height: windowFeatures.height,
        menuBarVisibility: windowFeatures.menuBarVisibility,
        statusBarVisibility: windowFeatures.statusBarVisibility,
        toolbarsVisibility: windowFeatures.toolbarsVisibility,
        allowsResizing: windowFeatures.allowsResizing
    )
}
// Keep popup retargeting intentionally narrow. Explicit cross-host alias groups
// preserve known first-party search flows without guessing at the public suffix
// list for arbitrary hosted tenants, while same-host scripted popups stay on
// the popup path so opener-dependent browser flows keep working.
private let browserNavigationSimpleUserGesturePopupRetargetHostAliases: [Set<String>] = [
    [
        "bilibili.com",
        "search.bilibili.com",
        "www.bilibili.com",
    ],
]

private func browserNavigationDefaultPort(for scheme: String) -> Int? {
    switch scheme {
    case "http":
        return 80
    case "https":
        return 443
    default:
        return nil
    }
}

private func browserNavigationShouldRetargetSimpleUserGesturePopup(
    requestURL: URL?,
    openerURL: URL?
) -> Bool {
    guard let requestURL,
          let openerURL,
          let requestScheme = requestURL.scheme?.lowercased(), !requestScheme.isEmpty,
          let openerScheme = openerURL.scheme?.lowercased(), !openerScheme.isEmpty,
          requestScheme == openerScheme,
          (requestURL.port ?? browserNavigationDefaultPort(for: requestScheme))
            == (openerURL.port ?? browserNavigationDefaultPort(for: openerScheme)),
          let requestHost = BrowserInsecureHTTPSettings.normalizeHost(requestURL.host ?? ""),
          let openerHost = BrowserInsecureHTTPSettings.normalizeHost(openerURL.host ?? "") else {
        return false
    }
    for aliases in browserNavigationSimpleUserGesturePopupRetargetHostAliases {
        if requestHost != openerHost,
           aliases.contains(requestHost),
           aliases.contains(openerHost) {
            return true
        }
    }
    return false
}

func browserNavigationDebugURL(_ url: URL?) -> String {
    guard let url,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return "nil"
    }
    components.query = nil
    components.fragment = nil
    return components.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "")"
}

func browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
    navigationType: WKNavigationType,
    requestMethod: String?,
    requestURL: URL?,
    openerURL: URL?,
    modifierFlags: NSEvent.ModifierFlags = [],
    buttonNumber: Int = 0,
    hasRecentMiddleClickIntent: Bool = false,
    currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type,
    currentEventButtonNumber: Int? = NSApp.currentEvent?.buttonNumber,
    popupFeaturesWereSpecified: Bool
) -> Bool {
    guard navigationType == .other else {
        return false
    }
    // Some sites use `window.open()` for plain same-site searches triggered by a
    // direct keyboard submit or left-click, without requesting popup chrome or
    // opener-style geometry. Route those to a normal tab while keeping
    // cross-site/OAuth-style popups on the popup path.
    guard browserNavigationHasSimpleUserActivation(currentEventType: currentEventType) else {
        return false
    }
    guard !browserNavigationShouldOpenInNewTab(
        navigationType: navigationType,
        modifierFlags: modifierFlags,
        buttonNumber: buttonNumber,
        hasRecentMiddleClickIntent: hasRecentMiddleClickIntent,
        currentEventType: currentEventType,
        currentEventButtonNumber: currentEventButtonNumber
    ) else {
        return false
    }
    guard (requestMethod ?? "GET").uppercased() == "GET" else {
        return false
    }
    guard !popupFeaturesWereSpecified else {
        return false
    }
    return browserNavigationShouldRetargetSimpleUserGesturePopup(
        requestURL: requestURL,
        openerURL: openerURL
    )
}

class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
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
    /// Direct reference to the download delegate — must be set synchronously in didBecome callbacks.
    var downloadDelegate: WKDownloadDelegate?
    /// The URL of the last navigation that was attempted. Used to preserve the omnibar URL
    /// when a provisional navigation fails (e.g. connection refused on localhost:3000).
    var lastAttemptedURL: URL?

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

        // Check if this response should be treated as a download.
        // Criteria: explicit Content-Disposition: attachment, or a MIME type
        // that WebKit cannot render inline.
        if let response = navigationResponse.response as? HTTPURLResponse {
            let contentDisposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            if contentDisposition.lowercased().hasPrefix("attachment") {
                NSLog("BrowserPanel download: content-disposition=attachment mime=%@ url=%@", mime, responseURL)
                #if DEBUG
                cmuxDebugLog("download.policy=download reason=content-disposition mime=\(mime)")
                #endif
                decisionHandler(.download)
                return
            }
        }

        if !canShow {
            NSLog("BrowserPanel download: cannotShowMIME mime=%@ url=%@", mime, responseURL)
            #if DEBUG
            cmuxDebugLog("download.policy=download reason=cannotShowMIME mime=\(mime)")
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

// MARK: - UI Delegate

class BrowserUIDelegate: NSObject, WKUIDelegate {
    var openInNewTab: ((URL) -> Void)?
    var requestNavigation: ((URLRequest, BrowserInsecureHTTPNavigationIntent) -> Void)?
    var presentAlert: BrowserAlertPresenter = browserPresentAlert
    var openPopup: ((WKWebViewConfiguration, WKWindowFeatures) -> WKWebView?)?
    var closeRequested: ((WKWebView) -> Void)?

    func webViewDidClose(_ webView: WKWebView) {
        closeRequested?(webView)
    }

    private func javaScriptDialogTitle(for webView: WKWebView) -> String {
        if let absolute = webView.url?.absoluteString, !absolute.isEmpty {
            return String(localized: "browser.dialog.pageSaysAt", defaultValue: "The page at \(absolute) says:")
        }
        return String(localized: "browser.dialog.pageSays", defaultValue: "This page says:")
    }

    private func presentDialog(
        _ alert: NSAlert,
        for webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void,
        cancel: @escaping () -> Void
    ) {
        presentAlert(alert, webView, completion, cancel)
    }

    /// Called when the page requests a new window (window.open(), target=_blank, etc.).
    ///
    /// Returns a live popup WKWebView created with WebKit's supplied configuration
    /// to preserve popup browsing-context semantics (window.opener, postMessage).
    /// Falls back to new-tab behavior only if popup creation is unavailable.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
#if DEBUG
        let currentEventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
        let currentEventButton = NSApp.currentEvent.map { String($0.buttonNumber) } ?? "nil"
        let navType = String(describing: navigationAction.navigationType)
        let requestMethod = navigationAction.request.httpMethod ?? "nil"
        let requestURL = navigationAction.request.url?.absoluteString ?? "nil"
        let targetMainFrame = navigationAction.targetFrame.map { $0.isMainFrame ? "1" : "0" } ?? "nil"
        let windowFeaturesSummary = [
            "x=\(windowFeatures.x?.stringValue ?? "nil")",
            "y=\(windowFeatures.y?.stringValue ?? "nil")",
            "w=\(windowFeatures.width?.stringValue ?? "nil")",
            "h=\(windowFeatures.height?.stringValue ?? "nil")",
            "toolbars=\(windowFeatures.toolbarsVisibility?.stringValue ?? "nil")",
            "resizable=\(windowFeatures.allowsResizing?.stringValue ?? "nil")",
            "status=\(windowFeatures.statusBarVisibility?.stringValue ?? "nil")",
            "menu=\(windowFeatures.menuBarVisibility?.stringValue ?? "nil")"
        ].joined(separator: ",")
        cmuxDebugLog(
            "browser.nav.createWebView navType=\(navType) button=\(navigationAction.buttonNumber) " +
            "mods=\(navigationAction.modifierFlags.rawValue) targetNil=\(navigationAction.targetFrame == nil ? 1 : 0) " +
            "targetMain=\(targetMainFrame) method=\(requestMethod) url=\(requestURL) " +
            "eventType=\(currentEventType) eventButton=\(currentEventButton) " +
            "windowFeatures={\(windowFeaturesSummary)}"
        )
#endif
        // External URL schemes → hand off to macOS, don't create a popup
        if let url = navigationAction.request.url,
           browserShouldRouteExternalNavigation(url) {
            browserHandleExternalNavigation(
                url,
                source: "uiDelegate",
                webView: webView,
                loadFallbackRequest: { [requestNavigation] request in
                    requestNavigation?(request, .currentTab)
                },
                presentAlert: presentAlert
            )
            return nil
        }

        let hasRecentMiddleClickIntent = CmuxWebView.hasRecentMiddleClickIntent(for: webView)
        let popupFeaturesWereSpecified = browserNavigationPopupFeaturesWereSpecified(windowFeatures: windowFeatures)
        let shouldOpenSimpleUserGesturePopupInCurrentTab = browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
            navigationType: navigationAction.navigationType,
            requestMethod: navigationAction.request.httpMethod,
            requestURL: navigationAction.request.url,
            openerURL: webView.url,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            hasRecentMiddleClickIntent: hasRecentMiddleClickIntent,
            popupFeaturesWereSpecified: popupFeaturesWereSpecified
        )

        if shouldOpenSimpleUserGesturePopupInCurrentTab {
            if let url = navigationAction.request.url {
#if DEBUG
                cmuxDebugLog(
                    "browser.nav.createWebView.action kind=requestNavigationSimpleUserGesture intent=currentTab " +
                    "url=\(browserNavigationDebugURL(url))"
                )
#endif
                if let requestNavigation {
                    requestNavigation(navigationAction.request, .currentTab)
                } else {
                    browserLoadRequest(navigationAction.request, in: webView)
                }
            }
            return nil
        }

        // Only treat scripted `.other` requests as popups when WebKit surfaced
        // explicit window features; bare `_blank` falls through to tabs.
        let isScriptedPopup = browserNavigationShouldCreatePopup(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            popupFeaturesWereSpecified: popupFeaturesWereSpecified,
            hasRecentMiddleClickIntent: hasRecentMiddleClickIntent
        )

        if isScriptedPopup, let popupWebView = openPopup?(configuration, windowFeatures) {
#if DEBUG
            cmuxDebugLog("browser.nav.createWebView.action kind=popup")
#endif
            return popupWebView
        }

        // Fallback: open in new tab (no opener linkage)
        if let url = navigationAction.request.url {
            if let requestNavigation {
                let intent: BrowserInsecureHTTPNavigationIntent = .newTab
#if DEBUG
                cmuxDebugLog(
                    "browser.nav.createWebView.action kind=requestNavigation intent=newTab " +
                    "url=\(browserNavigationDebugURL(url))"
                )
#endif
                requestNavigation(navigationAction.request, intent)
            } else {
#if DEBUG
                cmuxDebugLog("browser.nav.createWebView.action kind=openInNewTab url=\(url.absoluteString)")
#endif
                openInNewTab?(url)
            }
        }
        return nil
    }

    /// Handle <input type="file"> elements by presenting the native file picker.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.prompt)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: webView)
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        presentDialog(
            alert,
            for: webView,
            completion: { _ in completionHandler() },
            cancel: completionHandler
        )
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: webView)
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        presentDialog(
            alert,
            for: webView,
            completion: { response in
                completionHandler(response == .alertFirstButtonReturn)
            },
            cancel: {
                completionHandler(false)
            }
        )
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: webView)
        alert.informativeText = prompt
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field

        presentDialog(
            alert,
            for: webView,
            completion: { response in
                if response == .alertFirstButtonReturn {
                    completionHandler(field.stringValue)
                } else {
                    completionHandler(nil)
                }
            },
            cancel: {
                completionHandler(nil)
            }
        )
    }
}
