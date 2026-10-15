public import AppKit
public import Foundation
public import WebKit

/// The WebKit engine's ``BrowserPage``: a thin forwarding adapter over a
/// browser panel's existing `WKWebView`.
///
/// The adapter installs no navigation or UI delegate and changes no web view
/// setting. Every call forwards to the same `WKWebView` API the panel already
/// uses, so routing a call site through ``BrowserPage`` does not change
/// WebKit behavior. ``events`` observes the web view's key-value properties
/// only once a consumer reads it.
///
/// Developer tools forward to ``devToolsController`` (the panel), which owns
/// Web Inspector state.
@MainActor
public final class WebKitBrowserPage: BrowserPage {
    /// The wrapped web view.
    public let webView: WKWebView
    /// The app's decision handler. WebKit pages keep the panel's own
    /// `WKNavigationDelegate`/`WKUIDelegate`; see ``BrowserPageUIDelegate``.
    public weak var uiDelegate: (any BrowserPageUIDelegate)?
    /// Owner of Web Inspector state, usually the browser panel.
    public weak var devToolsController: (any WebKitBrowserPageDevToolsControlling)?

    private var addedUserScripts: [WKUserScript] = []
    private var observations: [NSKeyValueObservation] = []
    private var eventStream: AsyncStream<BrowserPageEvent>?
    private var eventContinuation: AsyncStream<BrowserPageEvent>.Continuation?
    private var lastReportedState: BrowserPageState?
    private var isClosed = false
    private var lastSetMuted = false

    /// Creates an adapter over a web view.
    /// - Parameters:
    ///   - webView: The panel's web view.
    ///   - devToolsController: The owner of Web Inspector state, or `nil`.
    public init(webView: WKWebView, devToolsController: (any WebKitBrowserPageDevToolsControlling)? = nil) {
        self.webView = webView
        self.devToolsController = devToolsController
    }

    /// Always ``BrowserEngineKind/webkit``.
    public var engineKind: BrowserEngineKind { .webkit }

    /// WebKit's features: Web Inspector, snapshots, downloads, user scripts,
    /// muting and in-pane fullscreen.
    public var capabilities: BrowserEngineCapabilities {
        WebKitBrowserPage.engineCapabilities
    }

    /// The capabilities of every WebKit page.
    public static let engineCapabilities: BrowserEngineCapabilities = [
        .devTools, .findMatchCount, .snapshots, .downloads, .paneFullscreen, .userScripts, .mediaMuting,
    ]

    /// Always ``BrowserPagePresentation/inView``.
    public var presentation: BrowserPagePresentation { .inView }

    /// The web view itself.
    public var contentView: NSView { webView }

    /// The web view's current state.
    public var state: BrowserPageState {
        let backForwardList = webView.backForwardList
        return BrowserPageState(
            url: webView.url,
            title: webView.title,
            isLoading: webView.isLoading,
            estimatedProgress: webView.estimatedProgress,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backURLs: backForwardList.backList.map(\.url),
            forwardURLs: backForwardList.forwardList.map(\.url),
            pageZoom: Double(webView.pageZoom),
            hasOnlySecureContent: webView.hasOnlySecureContent,
            isContentFullscreen: webView.fullscreenState == .inFullscreen
        )
    }

    /// State changes observed through key-value observation, starting with
    /// the current state. Created on first access; later reads return the
    /// same stream.
    public var events: AsyncStream<BrowserPageEvent> {
        if let eventStream { return eventStream }
        let (stream, continuation) = AsyncStream<BrowserPageEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        eventStream = stream
        eventContinuation = continuation
        if isClosed {
            continuation.finish()
        } else {
            startObserving()
            reportStateIfChanged()
        }
        return stream
    }

    // MARK: Navigation

    /// Forwards to `WKWebView.load(_:)`.
    /// - Parameter request: The request.
    public func load(_ request: URLRequest) {
        webView.load(request)
    }

    /// Forwards to `WKWebView.loadHTMLString(_:baseURL:)`.
    /// - Parameters:
    ///   - html: The document source.
    ///   - baseURL: The base URL.
    public func loadHTMLString(_ html: String, baseURL: URL?) {
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    /// Forwards to `WKWebView.goBack()`.
    public func goBack() {
        webView.goBack()
    }

    /// Forwards to `WKWebView.goForward()`.
    public func goForward() {
        webView.goForward()
    }

    /// Forwards to `WKWebView.reload()`.
    public func reload() {
        webView.reload()
    }

    /// Forwards to `WKWebView.reloadFromOrigin()`.
    public func reloadFromOrigin() {
        webView.reloadFromOrigin()
    }

    /// Forwards to `WKWebView.stopLoading()`.
    public func stop() {
        webView.stopLoading()
    }

    // MARK: JavaScript

    /// Forwards to `WKWebView.evaluateJavaScript`, in the page world or a
    /// named content world.
    /// - Parameters:
    ///   - script: The JavaScript source.
    ///   - world: The world to run in.
    /// - Returns: The completion value.
    /// - Throws: WebKit's evaluation error.
    public func evaluateJavaScript(_ script: String, in world: BrowserPageScriptWorld) async throws -> Any? {
        switch world {
        case .page:
            return try await webView.evaluateJavaScript(script)
        case .isolated(let name):
            return try await webView.evaluateJavaScript(script, in: nil, contentWorld: WKContentWorld.world(name: name))
        }
    }

    /// Forwards to `WKWebView.callAsyncJavaScript`.
    /// - Parameters:
    ///   - body: The async function body.
    ///   - arguments: Values bound to local names.
    ///   - world: The world to run in.
    /// - Returns: The resolved value.
    /// - Throws: WebKit's evaluation error.
    public func callAsyncJavaScript(
        _ body: String,
        arguments: [String: any Sendable],
        in world: BrowserPageScriptWorld
    ) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            body,
            arguments: arguments,
            in: nil,
            contentWorld: WebKitBrowserPage.contentWorld(for: world)
        )
    }

    /// Adds a `WKUserScript` to the web view's user content controller.
    /// - Parameter script: The script.
    public func addUserScript(_ script: BrowserPageUserScript) {
        let userScript = WKUserScript(
            source: script.source,
            injectionTime: script.injectionTime == .documentStart ? .atDocumentStart : .atDocumentEnd,
            forMainFrameOnly: script.isMainFrameOnly,
            in: WebKitBrowserPage.contentWorld(for: script.world)
        )
        addedUserScripts.append(userScript)
        webView.configuration.userContentController.addUserScript(userScript)
    }

    /// Removes the scripts this adapter added, keeping every other user
    /// script of the web view.
    public func removeAllUserScripts() {
        guard !addedUserScripts.isEmpty else { return }
        let controller = webView.configuration.userContentController
        let added = Set(addedUserScripts.map(ObjectIdentifier.init))
        let kept = controller.userScripts.filter { !added.contains(ObjectIdentifier($0)) }
        addedUserScripts.removeAll()
        controller.removeAllUserScripts()
        for script in kept {
            controller.addUserScript(script)
        }
    }

    // MARK: Zoom, devtools, snapshot

    /// Forwards to `WKWebView.pageZoom`.
    public var pageZoom: Double {
        get { Double(webView.pageZoom) }
        set { webView.pageZoom = CGFloat(newValue) }
    }

    /// Asks ``devToolsController``; `false` without one.
    public var isDevToolsVisible: Bool {
        devToolsController?.isDeveloperToolsVisible() ?? false
    }

    /// Asks ``devToolsController`` to open Web Inspector.
    public func showDevTools() {
        devToolsController?.showDeveloperTools()
    }

    /// Asks ``devToolsController`` to close Web Inspector.
    public func closeDevTools() {
        devToolsController?.hideDeveloperTools()
    }

    /// WebKit has no DevTools Protocol.
    /// - Throws: ``BrowserEngineError/unsupported(_:)`` always.
    public func sendDevToolsProtocolMessage(method: String, params: Data?) async throws -> Data {
        throw BrowserEngineError.unsupported("devToolsProtocol")
    }

    /// Forwards to `WKWebView.takeSnapshot(configuration:)`.
    /// - Parameter rect: The area in view coordinates, or `nil` for the visible page.
    /// - Returns: The captured image.
    /// - Throws: WebKit's snapshot error.
    public func takeSnapshot(rect: CGRect?) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        if let rect {
            configuration.rect = rect
        }
        return try await webView.takeSnapshot(configuration: configuration)
    }

    // MARK: Input, focus, visibility

    /// Makes the web view first responder of its window, or resigns it.
    /// - Parameter focused: `true` to focus the page.
    /// - Returns: `true` when the change took effect.
    @discardableResult
    public func setFocused(_ focused: Bool) -> Bool {
        guard let window = webView.window else { return false }
        if focused {
            return window.makeFirstResponder(webView)
        }
        guard let responder = window.firstResponder as? NSView, responder.isDescendant(of: webView) else {
            return true
        }
        return window.makeFirstResponder(nil)
    }

    /// WebKit derives visibility from the view hierarchy; the panel already
    /// manages attachment, so this does nothing.
    /// - Parameter visible: Ignored.
    public func setContentVisible(_ visible: Bool) {}

    /// WebKit has no trusted input path.
    /// - Throws: ``BrowserEngineError/unsupported(_:)`` always.
    public func dispatchInput(_ event: BrowserPageInputEvent) async throws {
        throw BrowserEngineError.unsupported("trustedInput")
    }

    // MARK: Media, restore, teardown

    /// Page audio mute through WebKit's media state. WebKit cannot report
    /// the mute state, so this reads the last value set through the adapter.
    public var isMuted: Bool {
        get { lastSetMuted }
        set {
            lastSetMuted = newValue
            webView.cmuxSetPageAudioMuted(newValue)
        }
    }

    /// Archives `WKWebView.interactionState`.
    /// - Returns: The state, or `nil` when WebKit returns none.
    public func exportRestoreState() -> BrowserPageRestoreState? {
        guard let data = webView.interactionState as? Data else { return nil }
        return .webKit(data)
    }

    /// Stops observing and finishes ``events``. The panel owns the web view's
    /// teardown, so the web view itself is left untouched.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: Private

    private static func contentWorld(for world: BrowserPageScriptWorld) -> WKContentWorld {
        switch world {
        case .page: .page
        case .isolated(let name): .world(name: name)
        }
    }

    private func startObserving() {
        // WKWebView changes these properties on the main thread, so the
        // handlers run on the main actor.
        let report: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.reportStateIfChanged() }
        }
        observations = [
            webView.observe(\.url, options: [.new]) { _, _ in report() },
            webView.observe(\.title, options: [.new]) { _, _ in report() },
            webView.observe(\.isLoading, options: [.new]) { _, _ in report() },
            webView.observe(\.estimatedProgress, options: [.new]) { _, _ in report() },
            webView.observe(\.canGoBack, options: [.new]) { _, _ in report() },
            webView.observe(\.canGoForward, options: [.new]) { _, _ in report() },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { _, _ in report() },
            webView.observe(\.fullscreenState, options: [.new]) { _, _ in report() },
        ]
    }

    private func reportStateIfChanged() {
        guard let eventContinuation else { return }
        let current = state
        guard current != lastReportedState else { return }
        lastReportedState = current
        eventContinuation.yield(.stateChanged(current))
    }
}
