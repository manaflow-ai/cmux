public import AppKit
public import Foundation
public import Observation
public import WebKit

/// A browser tab backed by one `WKWebView`.
@MainActor
@Observable
public final class WebKitTab: NSObject, BrowserTab {
    public let id: BrowserTabID
    public let profileID: BrowserProfileID
    public let engineKind: BrowserEngineKind = .webkit
    public let presentation: BrowserPresentation = .inView

    public var state: BrowserTabState { machine.state }
    public private(set) var favicon: NSImage?
    public private(set) var pendingPrompts: [BrowserPrompt] = []

    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?

    /// The underlying web view. Exposed for WebKit-only features (the
    /// automation executor); engine-neutral callers use `contentView`.
    @ObservationIgnored public let webView: WKWebView
    /// The web view's container (`WebKitPageContainer`): WebKit places an
    /// attached Web Inspector beside the web view inside it.
    public var contentView: NSView { container }
    @ObservationIgnored private let container: WebKitPageContainer

    private var machine = BrowserTabStateMachine()
    @ObservationIgnored private(set) weak var engine: WebKitEngine?
    /// Permission use and certificate failures of the current document (Page Info).
    @ObservationIgnored public let pageInfoActivity = PageInfoActivity()
    @ObservationIgnored var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var navigationIDs: [ObjectIdentifier: BrowserNavigationID] = [:]
    @ObservationIgnored private var nextNavigation: UInt64 = 0
    /// `observeNavigationEvents` handlers (WebKitTab+Navigations.swift).
    @ObservationIgnored var navigationObservers: [UUID: (BrowserNavigationEvent) -> Void] = [:]
    @ObservationIgnored var downloads: [ObjectIdentifier: BrowserDownload] = [:]
    @ObservationIgnored private var faviconTask: Task<Void, Never>?
    @ObservationIgnored private var findState = FindState()
    @ObservationIgnored private(set) var isClosed = false

    init(configuration: BrowserTabConfiguration, webViewConfiguration: WKWebViewConfiguration, engine: WebKitEngine,
         openedByPage: Bool = false) {
        self.id = configuration.id
        self.profileID = configuration.profile
        self.engine = engine
        let webView = WebKitWebView(frame: .zero, configuration: webViewConfiguration)
        self.webView = webView
        container = WebKitPageContainer(page: webView)
        super.init()

        webView.owner = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.underPageBackgroundColor = .clear
        // No white before the first page: the pane's theme color shows
        // through until a real page finishes (`PageBackground`). A page a
        // page opened draws WebKit's default at once.
        setDrawsPageBackground(!PageBackground.startsWithTheme(openedByPage: openedByPage))

        let controller = webViewConfiguration.userContentController
        controller.addUserScript(WKUserScript(
            source: PaneFullscreenScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.add(WeakScriptMessageHandler(self), name: PaneFullscreenScript.messageHandlerName)

        observeWebView()
        if configuration.zoom != 1 {
            setZoom(configuration.zoom)
        }
    }

    isolated deinit {
        faviconTask?.cancel()
    }

    /// WKWebView paints white behind every page by default. macOS has no
    /// public switch, so this uses WebKit's `_setDrawsBackground:` SPI
    /// through KVC ("drawsBackground"), checked first; without it the tab
    /// keeps WebKit's default.
    func setDrawsPageBackground(_ draws: Bool) {
        guard webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) else { return }
        webView.setValue(draws, forKey: "drawsBackground")
    }

    /// The first real page finished: from now on WebKit draws its default
    /// behind pages again (white for pages without a background).
    func pageDidFinish() {
        guard !PageBackground.isBlank(webView.url) else { return }
        setDrawsPageBackground(true)
    }

    // MARK: Navigation commands

    public func load(_ url: URL) { startLoad(url) }
    public func goBack() { startGoBack() }
    public func goForward() { startGoForward() }
    public func reload() { startReload() }

    public func stop() {
        webView.stopLoading()
        apply(.stopped)
    }

    // MARK: Focus and occlusion

    public func setFocused(_ focused: Bool) {
        guard let window = webView.window else { return }
        if focused {
            window.makeFirstResponder(webView)
        } else if (webView as? WebKitWebView)?.hasKeyboardFocus == true {
            window.makeFirstResponder(nil)
        }
    }

    /// WebKit draws in-view and throttles hidden views itself.
    public func setContentVisible(_ visible: Bool) {}

    // MARK: Snapshot, script, find

    public func snapshot() async throws -> CGImage {
        guard !isClosed else { throw BrowserTabError.closed }
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw BrowserTabError.snapshotUnavailable
        }
        return cgImage
    }

    public func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue {
        guard !isClosed else { throw BrowserTabError.closed }
        do {
            let result = try await webView.evaluateJavaScript(script, in: nil, contentWorld: world.contentWorld)
            return BrowserJSValue(foundation: result)
        } catch let error as WKError where error.code == .javaScriptResultTypeIsUnsupported {
            return .null
        } catch let error as WKError where error.code == .javaScriptExceptionOccurred {
            let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw BrowserTabError.javaScript(message)
        }
    }

    /// Runs `body` as an async function with named arguments. Safer than
    /// string interpolation for automation input.
    public func callFunction(
        _ body: String,
        arguments: [String: BrowserJSValue] = [:],
        world: BrowserScriptWorld = .isolated
    ) async throws -> BrowserJSValue {
        guard !isClosed else { throw BrowserTabError.closed }
        let result = try await webView.callAsyncJavaScript(
            body,
            arguments: arguments.mapValues(\.foundationValue),
            in: nil,
            contentWorld: world.contentWorld
        )
        return BrowserJSValue(foundation: result)
    }

    public func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        guard !isClosed, !text.isEmpty else {
            clearFind()
            return .none
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = direction == .backward
        configuration.caseSensitive = caseSensitive
        configuration.wraps = true
        let matchFound = (try? await webView.find(text, configuration: configuration))?.matchFound ?? false

        let count = try? await callFunction(
            FindScripts.countBody,
            arguments: ["needle": .string(text), "caseSensitive": .bool(caseSensitive)]
        ).numberValue.map { Int($0) }
        return findState.step(query: text, direction: direction, matchFound: matchFound, count: count)
    }

    public func clearFind() {
        findState = FindState()
        webView.evaluateJavaScript(FindScripts.clearSelection, completionHandler: nil)
    }

    // MARK: Zoom, fullscreen, devtools

    public func setZoom(_ zoom: Double) {
        let clamped = BrowserZoom.clamp(zoom)
        webView.pageZoom = clamped
        apply(.zoomChanged(clamped))
    }

    public func exitContentFullscreen() {
        webView.evaluateJavaScript(PaneFullscreenScript.exitScript, completionHandler: nil)
    }

    /// Leaves pane fullscreen now: the chrome returns at once, and the page
    /// is told (its shim exits and fires fullscreenchange).
    func leaveContentFullscreen() {
        apply(.contentFullscreenChanged(false))
        exitContentFullscreen()
    }

    /// Opens Web Inspector through WebKit's private `_inspector` object.
    /// There is no public API for this; if WebKit removes it, the user can
    /// still use "Inspect Element" from the context menu.
    public func showDevTools() {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector),
              let inspector = webView.perform(selector)?.takeUnretainedValue() as? NSObject else { return }
        let show = NSSelectorFromString("show")
        if inspector.responds(to: show) {
            inspector.perform(show)
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        faviconTask?.cancel()
        for prompt in pendingPrompts { prompt.respond(prompt.dismissalResponse) }
        pendingPrompts.removeAll()
        observations.removeAll()
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        container.removeFromSuperview()
    }

    // MARK: Internals shared with the delegate extension

    func apply(_ event: BrowserNavigationEvent) {
        let previousFavicon = machine.state.faviconURL
        machine.apply(event)
        for observer in navigationObservers.values { observer(event) }
        if machine.state.faviconURL != previousFavicon {
            faviconURLDidChange()
        }
    }

    func navigationID(for navigation: WKNavigation?, creating: Bool) -> BrowserNavigationID? {
        guard let navigation else {
            return creating ? allocateNavigationID() : state.activeNavigation
        }
        let key = ObjectIdentifier(navigation)
        if let id = navigationIDs[key] { return id }
        guard creating else { return nil }
        let id = allocateNavigationID()
        navigationIDs[key] = id
        return id
    }

    func forgetNavigation(_ navigation: WKNavigation?) {
        guard let navigation else { return }
        navigationIDs[ObjectIdentifier(navigation)] = nil
    }

    func allocateNavigationID() -> BrowserNavigationID {
        nextNavigation += 1
        return BrowserNavigationID(rawValue: nextNavigation)
    }

    func enqueuePrompt(_ kind: BrowserPromptKind, origin: String, completion: @escaping (BrowserPromptResponse) -> Void) {
        guard !isClosed else {
            completion(BrowserPrompt(kind: kind, origin: origin, completion: { _ in }).dismissalResponse)
            return
        }
        var prompt: BrowserPrompt?
        prompt = BrowserPrompt(kind: kind, origin: origin) { [weak self] response in
            self?.pendingPrompts.removeAll { $0 === prompt }
            completion(response)
        }
        if let prompt { pendingPrompts.append(prompt) }
    }

    func emit(_ intent: BrowserTabIntent) {
        delegate?.browserTab(self, didRequest: intent)
    }

    var hasDelegate: Bool { delegate != nil }

    func makeChildTab(configuration: WKWebViewConfiguration) -> WebKitTab? {
        engine?.makeWebKitTab(BrowserTabConfiguration(profile: profileID), webViewConfiguration: configuration)
    }

    var downloadsDirectory: URL {
        engine?.downloadsDirectory ?? DownloadDestination.defaultDirectory
    }

    func refreshFavicon() {
        faviconTask?.cancel()
        faviconTask = Task { [weak self] in
            guard let self,
                  let value = try? await self.evaluate(FaviconScript.source, world: .isolated),
                  let string = value.stringValue,
                  let url = URL(string: string),
                  !Task.isCancelled else { return }
            self.apply(.faviconChanged(url))
        }
    }

    // MARK: Private

    private func faviconURLDidChange() {
        guard let url = state.faviconURL else {
            favicon = nil
            return
        }
        guard let loader = engine?.faviconLoader else { return }
        let profile = profileID
        Task { [weak self] in
            let image = await loader.favicon(at: url, profile: profile)
            guard let self, self.state.faviconURL == url else { return }
            self.favicon = image
        }
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.apply(.urlChanged(webView.url)) }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.apply(.titleChanged(webView.title)) }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.apply(.progress(webView.estimatedProgress)) }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.syncHistory() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.syncHistory() }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.syncSecurity() }
            },
        ]
    }

    func syncHistory() {
        apply(.historyChanged(canGoBack: webView.canGoBack, canGoForward: webView.canGoForward))
        let list = webView.backForwardList
        apply(.historyListed(back: list.backList.suffix(Self.historyListLimit).map(\.url.absoluteString),
                             forward: list.forwardList.prefix(Self.historyListLimit).map(\.url.absoluteString)))
    }

    /// URLs kept on each side of the current entry (the daemon's tab record holds 20).
    static let historyListLimit = 20

    func syncSecurity() {
        guard !isClosed, state.phase == .committed || state.phase == .finished else { return }
        var security = BrowserTabStateMachine.security(for: webView.url)
        if security == .secure, !webView.hasOnlySecureContent {
            security = .mixedContent
        }
        apply(.securityChanged(security))
    }
}
