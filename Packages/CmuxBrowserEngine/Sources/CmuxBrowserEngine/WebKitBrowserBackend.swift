import AppKit
import Foundation
@preconcurrency import WebKit

/// Production backend that wraps `WKWebView`. This is the engine
/// `CmuxBrowserView` uses today and during the entire P3 migration
/// window — both flag values are valid until `ChromiumBrowserBackend`
/// is feature-complete.
@MainActor
final class WebKitBrowserBackend: NSObject, CmuxBrowserBackend {
    nonisolated static func versionString() -> String {
        // WKWebView ships with the OS WebKit. Surface the bundle version
        // so it's clear which WebKit the running build is bound to.
        let bundle = Bundle(identifier: "com.apple.WebKit")
        let v = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? bundle?.infoDictionary?["CFBundleVersion"] as? String
            ?? "unknown"
        return "WebKit \(v)"
    }

    let webView: WKWebView
    var navigationDelegate: CmuxNavigationDelegate?
    var uiDelegate: CmuxUIDelegate?
    let state = CmuxBrowserState()

    /// Maps the engine's underlying `WKNavigation` (whose identity we
    /// can't observe directly across the delegate methods) to a stable
    /// `CmuxNavigation` UUID. Strong references; entries cleared in
    /// the terminal delegate methods.
    private var navigationMap: [ObjectIdentifier: CmuxNavigation] = [:]

    /// KVO tokens. Retained for the lifetime of the backend.
    private var observations: [NSKeyValueObservation] = []

    private lazy var navigationBridge = NavigationBridge(owner: self)
    private lazy var uiBridge = UIBridge(owner: self)

    init(configuration: CmuxBrowserConfiguration) {
        let wk = WKWebViewConfiguration()
        wk.userContentController = configuration.userContentController.makeWKController()
        wk.preferences.javaScriptCanOpenWindowsAutomatically =
            configuration.allowsJavaScriptToOpenWindowsAutomatically
        wk.preferences.isElementFullscreenEnabled = true
        wk.allowsAirPlayForMediaPlayback = true
        wk.suppressesIncrementalRendering = configuration.suppressesIncrementalRendering
        wk.mediaTypesRequiringUserActionForPlayback =
            configuration.mediaTypesRequiringUserActionForPlayback.wkValue
        if let app = configuration.applicationNameForUserAgent {
            wk.applicationNameForUserAgent = app
        }
        // Bind a specific WKWebsiteDataStore when the caller wants a
        // non-default profile. Without this, all views would share the
        // default cookies/local storage.
        if let store = configuration.dataStore?.wkStore {
            wk.websiteDataStore = store
        }
        for (scheme, handler) in configuration.urlSchemeHandlers {
            wk.setURLSchemeHandler(URLSchemeShim(host: handler), forURLScheme: scheme)
        }
        self.webView = WKWebView(frame: .zero, configuration: wk)
        super.init()
        if let ua = configuration.customUserAgent {
            self.webView.customUserAgent = ua
        }
        self.webView.navigationDelegate = navigationBridge
        self.webView.uiDelegate = uiBridge
        installStateObservations()
    }

    private func installStateObservations() {
        let state = self.state
        // KVO observations push WKWebView state into CmuxBrowserState
        // synchronously on the main actor (KVO callbacks fire on the
        // calling thread, which for these properties is always main).
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [state] wv, _ in
                MainActor.assumeIsolated { state.url = wv.url }
            },
            webView.observe(\.title, options: [.initial, .new]) { [state] wv, _ in
                MainActor.assumeIsolated { state.title = wv.title }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [state] wv, _ in
                MainActor.assumeIsolated { state.isLoading = wv.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [state] wv, _ in
                MainActor.assumeIsolated { state.estimatedProgress = wv.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [state] wv, _ in
                MainActor.assumeIsolated { state.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [state] wv, _ in
                MainActor.assumeIsolated { state.canGoForward = wv.canGoForward }
            },
        ]
        state.pageZoom = webView.pageZoom
    }

    var pageZoom: CGFloat {
        get { webView.pageZoom }
        set {
            webView.pageZoom = newValue
            state.pageZoom = newValue
        }
    }

    var nsView: NSView { webView }
    var url: URL? { webView.url }
    var title: String? { webView.title }
    var isLoading: Bool { webView.isLoading }
    var estimatedProgress: Double { webView.estimatedProgress }
    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    var customUserAgent: String? { webView.customUserAgent }

    func load(_ request: URLRequest) -> CmuxNavigation {
        let wkNav = webView.load(request)
        return register(wkNav)
    }

    func loadHTMLString(_ html: String, baseURL: URL?) -> CmuxNavigation {
        let wkNav = webView.loadHTMLString(html, baseURL: baseURL)
        return register(wkNav)
    }

    func goBack() -> CmuxNavigation? { register(webView.goBack()) }
    func goForward() -> CmuxNavigation? { register(webView.goForward()) }
    func reload() -> CmuxNavigation? { register(webView.reload()) }
    func stopLoading() { webView.stopLoading() }

    func evaluateJavaScript(
        _ source: String,
        completionHandler: @escaping (Any?, Error?) -> Void
    ) {
        // WKWebView's `completionHandler` is declared `@Sendable @MainActor`.
        // Our protocol's is plain `@escaping`. We close over it as
        // `@unchecked Sendable` because both callers run on the main
        // actor and the closure is only invoked there.
        struct Closure: @unchecked Sendable {
            let body: (Any?, Error?) -> Void
        }
        let box = Closure(body: completionHandler)
        webView.evaluateJavaScript(source) { value, error in
            box.body(value, error)
        }
    }

    func setCustomUserAgent(_ userAgent: String?) {
        webView.customUserAgent = userAgent
    }

    func takeSnapshot(completionHandler: @escaping (CGImage?, Error?) -> Void) {
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, error in
            completionHandler(image?.cgImage(forProposedRect: nil, context: nil, hints: nil), error)
        }
    }

    // MARK: navigation map

    private func register(_ wkNav: WKNavigation?) -> CmuxNavigation {
        let navigation = CmuxNavigation()
        if let wkNav {
            navigationMap[ObjectIdentifier(wkNav)] = navigation
        }
        return navigation
    }

    fileprivate func resolve(_ wkNav: WKNavigation?) -> CmuxNavigation {
        guard let wkNav else { return CmuxNavigation() }
        if let known = navigationMap[ObjectIdentifier(wkNav)] {
            return known
        }
        let synthesized = CmuxNavigation()
        navigationMap[ObjectIdentifier(wkNav)] = synthesized
        return synthesized
    }

    fileprivate func clearNavigation(_ wkNav: WKNavigation?) {
        guard let wkNav else { return }
        navigationMap.removeValue(forKey: ObjectIdentifier(wkNav))
    }
}

// MARK: - Delegate bridges (forward WK → Cmux types)

extension WebKitBrowserBackend {
    final class NavigationBridge: NSObject, WKNavigationDelegate {
        weak var owner: WebKitBrowserBackend?
        init(owner: WebKitBrowserBackend) { self.owner = owner }

        @MainActor
        private func cmuxView() -> CmuxBrowserView? {
            // Walk up the NSView ancestry: the WKWebView is hosted by
            // a CmuxBrowserView. If not found, the call is a noop —
            // helps in unit tests where the WK view is unmounted.
            guard let owner else { return nil }
            return owner.webView.superview as? CmuxBrowserView
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            guard let delegate = owner?.navigationDelegate,
                  let view = cmuxView() else {
                decisionHandler(.allow, preferences); return
            }
            delegate.browserView(view,
                                 decidePolicyFor: navigationAction.cmux,
                                 decisionHandler: { policy in
                                     decisionHandler(policy.wk, preferences)
                                 })
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            guard let delegate = owner?.navigationDelegate,
                  let view = cmuxView() else {
                decisionHandler(.allow); return
            }
            delegate.browserView(view,
                                 decidePolicyFor: navigationResponse.cmux,
                                 decisionHandler: { policy in
                                     decisionHandler(policy.wk)
                                 })
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard let owner, let delegate = owner.navigationDelegate, let view = cmuxView() else { return }
            delegate.browserView(view, didStartProvisionalNavigation: owner.resolve(navigation))
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard let owner, let delegate = owner.navigationDelegate, let view = cmuxView() else { return }
            delegate.browserView(view, didCommit: owner.resolve(navigation))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let owner, let delegate = owner.navigationDelegate, let view = cmuxView() else { return }
            let nav = owner.resolve(navigation)
            delegate.browserView(view, didFinish: nav)
            owner.clearNavigation(navigation)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard let owner, let delegate = owner.navigationDelegate, let view = cmuxView() else { return }
            let nav = owner.resolve(navigation)
            delegate.browserView(view, didFail: nav, withError: error)
            owner.clearNavigation(navigation)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard let owner, let delegate = owner.navigationDelegate, let view = cmuxView() else { return }
            let nav = owner.resolve(navigation)
            delegate.browserView(view, didFailProvisionalNavigation: nav, withError: error)
            owner.clearNavigation(navigation)
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let delegate = owner?.navigationDelegate, let view = cmuxView() else {
                completionHandler(.performDefaultHandling, nil); return
            }
            delegate.browserView(view, didReceive: challenge, completionHandler: completionHandler)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let delegate = owner?.navigationDelegate, let view = cmuxView() else { return }
            delegate.browserViewWebContentProcessDidTerminate(view)
        }
    }

    final class UIBridge: NSObject, WKUIDelegate {
        weak var owner: WebKitBrowserBackend?
        init(owner: WebKitBrowserBackend) { self.owner = owner }

        @MainActor
        private func cmuxView() -> CmuxBrowserView? {
            owner?.webView.superview as? CmuxBrowserView
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // We do not currently bridge window.open() back through the
            // protocol. Hosts that need popups can implement
            // createBrowserViewWith on `CmuxUIDelegate`; the wrapper
            // returns the new view's underlying NSView/WKWebView.
            // Today: deny.
            _ = configuration
            _ = navigationAction
            _ = windowFeatures
            return nil
        }
    }
}

// MARK: - Bridging helpers

private extension WKNavigationActionPolicy {
    var cmux: CmuxNavigationActionPolicy {
        switch self {
        case .allow: return .allow
        case .cancel: return .cancel
        case .download: return .download
        @unknown default: return .allow
        }
    }
}

private extension CmuxNavigationActionPolicy {
    var wk: WKNavigationActionPolicy {
        switch self {
        case .allow: return .allow
        case .cancel: return .cancel
        case .download: return .download
        }
    }
}

private extension WKNavigationResponsePolicy {
    var cmux: CmuxNavigationResponsePolicy {
        switch self {
        case .allow: return .allow
        case .cancel: return .cancel
        case .download: return .download
        @unknown default: return .allow
        }
    }
}

private extension CmuxNavigationResponsePolicy {
    var wk: WKNavigationResponsePolicy {
        switch self {
        case .allow: return .allow
        case .cancel: return .cancel
        case .download: return .download
        }
    }
}

private extension WKNavigationAction {
    var cmux: CmuxNavigationAction {
        CmuxNavigationAction(
            request: request,
            sourceFrame: sourceFrame.cmux,
            targetFrame: targetFrame?.cmux,
            navigationType: navigationType.cmux,
            modifierFlags: modifierFlags,
            buttonNumber: buttonNumber,
            shouldPerformDownload: shouldPerformDownload
        )
    }
}

private extension WKNavigationType {
    var cmux: CmuxNavigationAction.NavigationType {
        switch self {
        case .linkActivated: return .linkActivated
        case .formSubmitted: return .formSubmitted
        case .backForward: return .backForward
        case .reload: return .reload
        case .formResubmitted: return .formResubmitted
        case .other: return .other
        @unknown default: return .other
        }
    }
}

private extension WKFrameInfo {
    var cmux: CmuxFrameInfo {
        CmuxFrameInfo(
            isMainFrame: isMainFrame,
            request: request,
            securityOriginHost: securityOrigin.host,
            securityOriginPort: securityOrigin.port == 0 ? nil : securityOrigin.port
        )
    }
}

private extension WKNavigationResponse {
    var cmux: CmuxNavigationResponse {
        CmuxNavigationResponse(
            response: response,
            isForMainFrame: isForMainFrame,
            canShowMIMEType: canShowMIMEType
        )
    }
}

private extension CmuxBrowserConfiguration.MediaPlaybackRequirement {
    var wkValue: WKAudiovisualMediaTypes {
        switch self {
        case .none: return []
        case .audio: return .audio
        case .video: return .video
        case .all: return .all
        }
    }
}

// MARK: - WKUserContentController shim

extension CmuxUserContentController {
    /// Builds a fresh `WKUserContentController` from this controller's
    /// scripts + handlers. The returned controller holds strong
    /// references to the registered handlers via a shim adapter.
    @MainActor
    func makeWKController() -> WKUserContentController {
        let wk = WKUserContentController()
        for s in userScripts {
            let wkScript = WKUserScript(
                source: s.source,
                injectionTime: s.injectionTime.wk,
                forMainFrameOnly: s.forMainFrameOnly
            )
            wk.addUserScript(wkScript)
        }
        for (name, handler) in messageHandlers {
            let shim = WKMessageHandlerShim(host: handler)
            wk.add(shim, name: name)
        }
        return wk
    }
}

private extension CmuxUserScript.InjectionTime {
    var wk: WKUserScriptInjectionTime {
        switch self {
        case .atDocumentStart: return .atDocumentStart
        case .atDocumentEnd: return .atDocumentEnd
        }
    }
}

private final class WKMessageHandlerShim: NSObject, WKScriptMessageHandler {
    let host: any CmuxScriptMessageHandler
    init(host: any CmuxScriptMessageHandler) { self.host = host }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = CmuxScriptMessageBody.from(any: message.body)
        let url = message.frameInfo.request.url ?? message.frameInfo.securityOrigin.urlIfAvailable
        let cmux = CmuxScriptMessage(
            name: message.name,
            body: body,
            frameURL: url,
            isMainFrame: message.frameInfo.isMainFrame
        )
        host.didReceive(cmux)
    }
}

private extension WKSecurityOrigin {
    var urlIfAvailable: URL? {
        guard !host.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = self.protocol
        c.host = host
        c.port = port == 0 ? nil : port
        return c.url
    }
}

extension CmuxScriptMessageBody {
    /// Walk an `Any` value (the type WKScriptMessage.body returns) into
    /// the typed enum. Supports the JSON-ish set WebKit hands back.
    public static func from(any value: Any) -> CmuxScriptMessageBody {
        if value is NSNull { return .null }
        if let b = value as? Bool {
            // NSNumber coerces to Bool too aggressively; check NSNumber first
            // below. Keep this as a fallback for pure Bool.
            return .bool(b)
        }
        if let n = value as? NSNumber {
            let cf = CFGetTypeID(n) == CFBooleanGetTypeID()
            if cf { return .bool(n.boolValue) }
            // Best-effort: integer if exact, else double.
            if n.doubleValue == Double(n.int64Value) {
                return .int(n.int64Value)
            }
            return .double(n.doubleValue)
        }
        if let s = value as? String { return .string(s) }
        if let d = value as? Data { return .data(d) }
        if let a = value as? [Any] {
            return .array(a.map { CmuxScriptMessageBody.from(any: $0) })
        }
        if let dict = value as? [String: Any] {
            var out: [String: CmuxScriptMessageBody] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = CmuxScriptMessageBody.from(any: v)
            }
            return .dictionary(out)
        }
        // Fallback: stringify
        return .string(String(describing: value))
    }
}

// MARK: - URL scheme handler shim

private final class URLSchemeShim: NSObject, WKURLSchemeHandler {
    let host: any CmuxURLSchemeHandler
    init(host: any CmuxURLSchemeHandler) { self.host = host }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        // WKURLSchemeTask is not Sendable. The completion callbacks
        // are routed back to the main thread, where WK invokes them,
        // so we use an unchecked Sendable shim to carry the task
        // reference into our closures.
        struct TaskBox: @unchecked Sendable {
            let task: any WKURLSchemeTask
        }
        let box = TaskBox(task: urlSchemeTask)
        let cmuxTask = CmuxURLSchemeTask(
            request: urlSchemeTask.request,
            respond: { response in
                MainActor.assumeIsolated { box.task.didReceive(response) }
            },
            data: { data in
                MainActor.assumeIsolated { box.task.didReceive(data) }
            },
            finish: {
                MainActor.assumeIsolated { box.task.didFinish() }
            },
            fail: { error in
                MainActor.assumeIsolated { box.task.didFailWithError(error) }
            }
        )
        host.startURLSchemeTask(cmuxTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // We don't currently propagate cancellation. Most consumers
        // don't care; revisit when a callsite needs it.
        _ = urlSchemeTask
    }
}
