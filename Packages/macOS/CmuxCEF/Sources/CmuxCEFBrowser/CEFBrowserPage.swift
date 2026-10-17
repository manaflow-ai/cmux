public import AppKit
public import CmuxBrowser
public import CmuxCEF
public import CmuxCEFExtensions
public import Foundation

/// The Chromium engine's ``BrowserPage``: a CEF browser whose Chromium
/// window tracks ``contentView``.
///
/// JavaScript runs through the DevTools Protocol (`Runtime.evaluate`), so
/// results are the Foundation JSON objects WebKit returns. User scripts use
/// `Page.addScriptToEvaluateOnNewDocument`; snapshots use
/// `Page.captureScreenshot`; trusted input uses `Input.dispatch*Event`.
@MainActor
public final class CEFBrowserPage: BrowserPage {
    /// The wrapped Chromium page.
    public let browser: CEFBrowser
    /// DevTools, native find, zoom and the context menu of the page.
    public let features: CEFPageFeatures
    /// The app's decision handler, held weakly.
    public weak var uiDelegate: (any BrowserPageUIDelegate)?

    private var eventStream: AsyncStream<BrowserPageEvent>?
    private var eventContinuation: AsyncStream<BrowserPageEvent>.Continuation?
    private var pendingEvents: [BrowserPageEvent] = []
    private var userScriptIdentifiers: [String] = []
    /// User scripts added before the Chromium browser existed.
    private(set) var pendingUserScriptSources: [String] = []
    private var devToolsVisible = false
    private var muted = false
    private var lastFaviconURL: URL?
    private let faviconFetcher = CEFFaviconFetcher()
    private var isClosed = false
    /// Finds the helper process of a renderer; set by the provider, shared by its pages.
    var rendererProcesses: CEFRendererProcessResolver?
    /// Kept to give popups this page opens the same feature wiring.
    let shimProvider: @MainActor () -> CEFShimLibrary?
    private let devToolsLayoutStore: BrowserDevToolsLayoutStore
    /// `cmux_shim_set_navigation_guard` mode bits this page wants.
    private var navigationGuardMode: Int32 = 0
    /// The mode last applied to the Chromium browser, nil before it exists.
    private var appliedNavigationGuardMode: Int32?
    /// JavaScript dialogs waiting for the UI delegate, by shim token.
    private var pendingDialogs: [Int32: Task<Void, Never>] = [:]
    /// Captures running while the page is hidden, the occlusion the page had
    /// before the first of them, and the off-screen window holding a page no
    /// window shows during them (CEFBrowserPage+HiddenCapture).
    var hiddenCapture = (
        depth: 0, savedOcclusion: [CGRect](), wantsVisible: true, renderWindow: CEFCaptureRenderWindow?.none
    )
    /// Permission prompts and downloads of this page (CEFBrowserPage+Data.swift).
    let dataBridge = CEFBrowserPageDataBridge()
    /// Password filling and save offers (CEFBrowserPage+Passwords.swift): the
    /// per-tab fill switch last sent, the browser it was sent to, and the save
    /// offers waiting for the person, by Chromium prompt id.
    var passwords = (
        fill: PasswordFillState(), browserID: Int32?.none, offers: [Int32: Task<Void, Never>]()
    )
    /// `true` once an agent drove the page (``markAgentDriven()``); never cleared.
    public internal(set) var isAgentDriven = false
    /// DevTools protocol events automation reads back, and whether automation
    /// asked for them, per Chromium browser (CEFBrowserPage+ProtocolTelemetry).
    var telemetry = (
        recorder: BrowserProtocolTelemetryRecorder(), wanted: false, enabledBrowserID: Int32?.none
    )

    /// The capabilities of every Chromium page.
    public static let engineCapabilities: BrowserEngineCapabilities = [
        .devTools, .devToolsProtocol, .trustedInput, .snapshots, .paneFullscreen,
        .crossOriginFrames, .userScripts, .findMatchCount, .nativeFind, .downloads,
    ]

    /// The page's extension side (toolbar actions, extension calls); nil
    /// when the engine was created without extension support.
    public let extensionSupport: CEFExtensionPageSupport?

    /// Wraps a CEF browser and starts receiving its events.
    /// - Parameters:
    ///   - browser: The Chromium page.
    ///   - shim: The shim calls the page's features make, `nil` while CEF is not running.
    ///   - devToolsLayoutStore: Remembers the DevTools dock side and sizes.
    ///   - extensions: The engine's extension stores, or nil for a page without extensions.
    public init(
        browser: CEFBrowser,
        shim: @escaping @MainActor () -> CEFShimLibrary?,
        devToolsLayoutStore: BrowserDevToolsLayoutStore,
        extensions: CEFExtensionStores? = nil
    ) {
        self.browser = browser
        self.shimProvider = shim
        self.devToolsLayoutStore = devToolsLayoutStore
        features = CEFPageFeatures(
            shim: CEFShimPageFeatures(library: shim),
            browserID: { [weak browser] in browser?.browserID },
            pageView: browser.hostView,
            layoutStore: devToolsLayoutStore
        )
        extensionSupport = extensions.map { stores in
            CEFExtensionPageSupport(profileID: browser.configuration.profile, stores: stores) { [weak browser] in
                browser?.browserID
            }
        }
        browser.onEvent = { [weak self] event in
            self?.handle(event)
        }
        browser.onWindowCreated = { [weak self] id in
            // Before the first document: an agent-driven page never fills.
            self?.applyPasswordFill()
            self?.enableProtocolTelemetryIfWanted(browserID: id)
            self?.registerPendingUserScripts(browserID: id)
        }
        // A popup's browser exists already.
        applyPasswordFill()
    }

    /// Always ``BrowserEngineKind/chromium``.
    public var engineKind: BrowserEngineKind { .chromium }

    /// Chromium's features.
    public var capabilities: BrowserEngineCapabilities { Self.engineCapabilities }

    /// Chromium draws in a window of its own that tracks ``contentView``.
    public var presentation: BrowserPagePresentation { .childWindow }

    /// The page with its docked DevTools; the Chromium window tracks the page's host view inside it.
    public var contentView: NSView { features.paneView }

    /// The page state in engine-neutral form.
    public var state: BrowserPageState {
        Self.pageState(browser.state)
    }

    /// Page events. The first read returns the stream with the current
    /// state; later reads return the same stream.
    public var events: AsyncStream<BrowserPageEvent> {
        if let eventStream { return eventStream }
        let (stream, continuation) = AsyncStream<BrowserPageEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        eventStream = stream
        eventContinuation = continuation
        continuation.yield(.stateChanged(state))
        for event in pendingEvents {
            continuation.yield(event)
        }
        pendingEvents.removeAll()
        if isClosed { continuation.finish() }
        return stream
    }

    // MARK: Navigation

    /// Loads the request's URL. Chromium loads by URL only; method, body and
    /// headers are not carried.
    /// - Parameter request: The request.
    public func load(_ request: URLRequest) {
        guard let url = request.url else { return }
        browser.load(url)
        // A page loaded in a pane that has never been shown (a background
        // workspace, `--focus false`) starts now, as a hidden WebKit page
        // does, instead of waiting for its view to enter a window.
        browser.createNow()
    }

    /// Loads an HTML document as a `data:` URL.
    /// - Parameters:
    ///   - html: The document source.
    ///   - baseURL: Ignored; a `data:` document has no base URL.
    public func loadHTMLString(_ html: String, baseURL: URL?) {
        let encoded = Data(html.utf8).base64EncodedString()
        guard let url = URL(string: "data:text/html;charset=utf-8;base64,\(encoded)") else { return }
        browser.load(url)
        browser.createNow()
    }

    /// Goes back.
    public func goBack() { browser.goBack() }
    /// Goes forward.
    public func goForward() { browser.goForward() }
    /// Chromium's back/forward list for Back and Forward history menus.
    public func navigationList() -> CEFNavigationList? { browser.navigationList() }
    /// Goes `offset` entries back (negative) or forward in the history.
    @discardableResult
    public func goToEntry(offset: Int) -> Bool { browser.goToEntry(offset: offset) }
    /// Reloads.
    public func reload() { browser.reload() }

    /// Reloads bypassing the cache (`Page.reload` with `ignoreCache`).
    public func reloadFromOrigin() {
        Task { @MainActor [browser] in
            _ = try? await browser.devTools(method: "Page.reload", paramsJSON: Self.json(["ignoreCache": true]))
        }
    }

    /// Stops loading.
    public func stop() { browser.stop() }

    // MARK: JavaScript

    /// Evaluates a script in the main world, awaiting a returned promise.
    /// - Parameters:
    ///   - script: The JavaScript source.
    ///   - world: ``BrowserPageScriptWorld/page``; isolated worlds are not supported yet.
    /// - Returns: The completion value as Foundation JSON objects.
    /// - Throws: ``BrowserEngineError/javaScript(_:)`` when the script throws,
    ///   ``BrowserEngineError/pageClosed`` when the page is gone.
    public func evaluateJavaScript(_ script: String, in world: BrowserPageScriptWorld) async throws -> Any? {
        guard world == .page else { throw BrowserEngineError.unsupported("isolatedWorld") }
        do {
            return try await browser.evaluateJavaScript(script)
        } catch let error as CEFError {
            throw Self.engineError(error)
        }
    }

    /// Runs `body` as an async function with `arguments` bound to local names.
    /// - Parameters:
    ///   - body: The function body.
    ///   - arguments: JSON-compatible values keyed by JavaScript identifiers.
    ///   - world: ``BrowserPageScriptWorld/page``; isolated worlds are not supported yet.
    /// - Returns: The resolved value.
    /// - Throws: As ``evaluateJavaScript(_:in:)``.
    public func callAsyncJavaScript(
        _ body: String,
        arguments: [String: any Sendable],
        in world: BrowserPageScriptWorld
    ) async throws -> Any? {
        let names = arguments.keys.sorted()
        let values = names.map { arguments[$0] ?? NSNull() }
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values),
              let argumentList = String(data: data, encoding: .utf8) else {
            throw BrowserEngineError.javaScript("arguments are not JSON")
        }
        let parameters = names.joined(separator: ", ")
        let script = "(async (\(parameters)) => {\n\(body)\n})(...\(argumentList))"
        return try await evaluateJavaScript(script, in: world)
    }

    /// Injects a script into every new document of this page.
    /// - Parameter script: The script; `documentEnd` scripts wait for `DOMContentLoaded`.
    public func addUserScript(_ script: BrowserPageUserScript) {
        let source = Self.userScriptSource(script)
        guard browser.browserID != nil else {
            // Registered synchronously when the browser is created, before
            // its first load (`registerPendingUserScripts`).
            pendingUserScriptSources.append(source)
            return
        }
        let params = Self.json(["source": source])
        Task { @MainActor [weak self, browser] in
            guard let result = try? await browser.devTools(
                method: "Page.addScriptToEvaluateOnNewDocument",
                paramsJSON: params
            ), let identifier = Self.jsonObject(result)?["identifier"] as? String else { return }
            self?.userScriptIdentifiers.append(identifier)
        }
    }

    /// Sends the scripts added before the browser existed, in order, right
    /// before its first load. Their DevTools identifiers are not collected,
    /// so ``removeAllUserScripts()`` cannot remove them later.
    func registerPendingUserScripts(browserID: Int32) {
        let sources = pendingUserScriptSources
        pendingUserScriptSources.removeAll()
        guard !sources.isEmpty, let shim = shimProvider() else { return }
        // CEF's DevTools agent can acknowledge a new-document script while
        // silently dropping it unless the Page domain is enabled first. This
        // path runs synchronously before the initial navigation, so enable the
        // domain through the shim before registering telemetry, init scripts,
        // and other page-start hooks.
        let methods = Self.pendingUserScriptMethods()
        _ = shim.devToolsCall(browserID, methods[0], "{}")
        for source in sources {
            let params = Self.json(["source": source])
            _ = shim.devToolsCall(browserID, methods[1], params)
        }
    }

    /// The DevTools methods needed to install queued page-start scripts.
    ///
    /// Keeping this small protocol sequence in one value makes the ordering
    /// testable without loading the CEF dylib in package tests.
    nonisolated static func pendingUserScriptMethods() -> [String] {
        ["Page.enable", "Page.addScriptToEvaluateOnNewDocument"]
    }

    /// The script source as Chromium runs it: `documentEnd` waits for
    /// `DOMContentLoaded`; main-frame-only scripts skip subframes.
    nonisolated static func userScriptSource(_ script: BrowserPageUserScript) -> String {
        var source = script.source
        if script.injectionTime == .documentEnd {
            source = "document.addEventListener('DOMContentLoaded', () => {\n\(source)\n}, { once: true });"
        }
        if script.isMainFrameOnly {
            source = "if (window === window.top) {\n\(source)\n}"
        }
        return source
    }

    /// Removes every script added with ``addUserScript(_:)``.
    public func removeAllUserScripts() {
        pendingUserScriptSources.removeAll()
        let identifiers = userScriptIdentifiers
        userScriptIdentifiers.removeAll()
        Task { @MainActor [browser] in
            for identifier in identifiers {
                _ = try? await browser.devTools(
                    method: "Page.removeScriptToEvaluateOnNewDocument",
                    paramsJSON: Self.json(["identifier": identifier])
                )
            }
        }
    }

    // MARK: Zoom, devtools, snapshot

    /// Page zoom factor.
    public var pageZoom: Double {
        get { browser.state.zoom }
        set { browser.setZoom(newValue) }
    }

    /// `true` while Chromium's DevTools are open for this page.
    public var isDevToolsVisible: Bool { devToolsVisible }

    /// Opens Chromium's DevTools, docked by the pane's DevTools layout.
    public func showDevTools() { features.devTools.perform(.show) }

    /// Closes Chromium's DevTools.
    public func closeDevTools() { features.devTools.perform(.close) }

    /// Sends a DevTools Protocol command.
    /// - Parameters:
    ///   - method: The CDP method.
    ///   - params: JSON-encoded params, or `nil`.
    /// - Returns: The JSON-encoded result.
    /// - Throws: ``BrowserEngineError`` on a protocol error or closed page.
    public func sendDevToolsProtocolMessage(method: String, params: Data?) async throws -> Data {
        let paramsJSON = params.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        do {
            let result = try await browser.devTools(method: method, paramsJSON: paramsJSON)
            return Data(result.utf8)
        } catch let error as CEFError {
            throw Self.engineError(error)
        }
    }

    /// Captures the page with `Page.captureScreenshot`.
    /// - Parameter rect: The area in view (CSS pixel) coordinates, or `nil` for the viewport.
    /// - Returns: The captured image.
    /// - Throws: ``BrowserEngineError`` when the capture fails.
    public func takeSnapshot(rect: CGRect?) async throws -> NSImage {
        var params: [String: Any] = ["format": "png"]
        if let rect {
            params["clip"] = [
                "x": rect.origin.x, "y": rect.origin.y,
                "width": rect.size.width, "height": rect.size.height, "scale": 1,
            ]
        }
        let result: String
        do {
            result = try await browser.devTools(method: "Page.captureScreenshot", paramsJSON: Self.json(params))
        } catch let error as CEFError {
            throw Self.engineError(error)
        }
        guard let encoded = Self.jsonObject(result)?["data"] as? String,
              let data = Data(base64Encoded: encoded),
              let image = NSImage(data: data) else {
            throw BrowserEngineError.unsupported("snapshot")
        }
        return image
    }

    // MARK: Input, focus, visibility

    /// Gives or takes keyboard focus.
    /// - Parameter focused: `true` to focus the page.
    /// - Returns: `true`; Chromium applies focus once the page is shown.
    @discardableResult
    public func setFocused(_ focused: Bool) -> Bool {
        browser.setFocused(focused)
        return true
    }

    /// Shows or hides the page. The Chromium window follows ``contentView``'s
    /// presentation, and a pane keeps the views of its other tabs in the
    /// window, so a tab that is not on screen hides its host view: Chromium
    /// then sees the page hidden and stops its frames and timers, as WebKit
    /// does for a hidden web view.
    /// - Parameter visible: `true` when the page is on screen.
    public func setContentVisible(_ visible: Bool) {
        hiddenCapture.wantsVisible = visible
        // While a capture of the hidden page runs, only its cover changes now.
        if hiddenCapture.depth > 0 { return captureVisibilityChanged(visible) }
        guard browser.hostView.isHidden == visible else { return }
        browser.hostView.isHidden = !visible
    }

    /// Delivers a trusted input event through `Input.dispatch*Event`.
    /// - Parameter event: The event.
    /// - Throws: ``BrowserEngineError`` when Chromium rejects it.
    public func dispatchInput(_ event: BrowserPageInputEvent) async throws {
        for (method, params) in Self.inputCommands(for: event) {
            _ = try await sendDevToolsProtocolMessage(method: method, params: Data(Self.json(params).utf8))
        }
    }

    // MARK: Media, restore, teardown

    /// The last mute state set through this page. Chromium page muting is
    /// not wired yet, so setting it does not silence the page.
    public var isMuted: Bool {
        get { muted }
        set { muted = newValue }
    }

    /// Turns Chromium's agent navigation guard on or off (mode bit 4): while
    /// an agent drives the page, a main-frame navigation, redirect or
    /// history step to a Chromium internal page is cancelled in Chromium.
    /// Applied as soon as the browser exists.
    /// - Parameter enabled: `true` while an agent drives the page.
    public func setAgentNavigationGuard(_ enabled: Bool) {
        if enabled {
            navigationGuardMode |= Self.agentNavigationGuardBit
        } else {
            navigationGuardMode &= ~Self.agentNavigationGuardBit
        }
        applyNavigationGuardIfNeeded()
    }

    static let agentNavigationGuardBit: Int32 = 4

    private func applyNavigationGuardIfNeeded() {
        guard let id = browser.browserID, appliedNavigationGuardMode != navigationGuardMode,
              let shim = CEFRuntime.shared.shim else { return }
        shim.setNavigationGuard(id, navigationGuardMode)
        appliedNavigationGuardMode = navigationGuardMode
    }

    /// Answers a renderer hang.
    /// - Parameter terminate: `true` ends the renderer.
    public func answerUnresponsive(terminate: Bool) {
        browser.answerUnresponsive(terminate: terminate)
    }

    /// Chromium's navigation state.
    /// - Returns: The state, or `nil` before the page exists.
    public func exportRestoreState() -> BrowserPageRestoreState? {
        browser.navigationState().map(BrowserPageRestoreState.chromium)
    }

    /// Closes the Chromium page and finishes ``events``. Idempotent.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        dataBridge.pageWillClose(self)
        endPasswordOffers(answer: false)
        pendingDialogs.values.forEach { $0.cancel() }
        pendingDialogs.removeAll()
        features.tearDown()
        browser.close()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: Events

    private func handle(_ event: CEFBrowserEvent) {
        switch event {
        case .stateChanged(let cefState):
            // The browser may have been created since the guard was set.
            applyNavigationGuardIfNeeded()
            applyPasswordFill()
            extensionSupport?.noteBrowserID()
            emit(.stateChanged(Self.pageState(cefState)))
            if cefState.faviconURL != lastFaviconURL {
                lastFaviconURL = cefState.faviconURL
                updateFavicon(cefState.faviconURL)
            }
        case .loadStarted(let url, _):
            // CEF's OnLoadStart runs once the navigation has committed.
            dataBridge.pageWillLoad(self)
            emit(.navigationStarted(url))
            emit(.navigationCommitted(url))
        case .loadFinished:
            emit(.navigationFinished(browser.state.url))
        case .loadFailed(let code, let message, let url, let chromiumInterstitial):
            emit(.navigationFailed(url, code: code, message: message, showsEngineErrorPage: chromiumInterstitial))
        case .newBrowser(let popup, let disposition, let features, let userGesture):
            handleNewBrowser(popup, disposition: disposition, features: features, userGesture: userGesture)
        case .closeRequested:
            emit(.closeRequested)
        case .closed:
            // The runtime routes Chromium's before-close to the browser, not as a shim event.
            features.tearDown()
            eventContinuation?.finish()
        case .shim(let shimEvent):
            handle(shimEvent)
        }
    }

    private func handle(_ event: CEFShimEvent) {
        features.handle(event)
        if let pageEvent = Self.pageEvent(forShimEvent: event) {
            if case .devToolsVisibilityChanged(let open) = pageEvent { devToolsVisible = open }
            emit(pageEvent)
            return
        }
        switch event {
        case .devToolsMessage(_, let json):
            receiveProtocolMessage(json)
        case .jsDialog(_, let token, let kind, let message, let origin, let defaultText, let isReload):
            handleJavaScriptDialog(token: token, kind: kind, message: message, origin: origin,
                                   defaultText: defaultText, isReload: isReload)
        case .jsDialogDismissed(_, let token):
            pendingDialogs.removeValue(forKey: token)?.cancel()
        case .passwordPrompt(_, let promptID, let json):
            handlePasswordPrompt(promptID: promptID, json: json)
        default:
            // Permissions and downloads (CEFBrowserPage+Data.swift).
            dataBridge.handle(event, page: self)
        }
    }

    /// The page event a shim event becomes as is, or `nil` for one the page
    /// answers itself (dialogs) or hands to its data bridge.
    nonisolated static func pageEvent(forShimEvent event: CEFShimEvent) -> BrowserPageEvent? {
        switch event {
        case .devToolsOpened: .devToolsVisibilityChanged(true)
        case .devToolsClosed: .devToolsVisibilityChanged(false)
        case .fullscreen(_, let entering): .contentFullscreenChanged(entering)
        case .renderTerminated(_, let status, let code, _): .processTerminated(processExit(status: status, code: code))
        case .renderUnresponsive: .unresponsiveChanged(true)
        case .renderResponsive: .unresponsiveChanged(false)
        // Tab or Shift+Tab past the page's last or first control.
        case .takeFocus(_, let forward): .focusLeftPage(forward: forward)
        default: nil
        }
    }

    // MARK: JavaScript dialogs

    /// Chromium shows no dialog of its own and waits for the answer, so
    /// every dialog is answered: by the UI delegate, or with Chrome's
    /// defaults (OK for an alert and Leave, Cancel otherwise) without one.
    private func handleJavaScriptDialog(
        token: Int32, kind: CEFJSDialogKind, message: String, origin: String, defaultText: String, isReload: Bool
    ) {
        let pageKind: BrowserPageJavaScriptDialog.Kind = switch kind {
        case .alert: .alert
        case .confirm: .confirm
        case .prompt: .prompt(defaultText: defaultText)
        case .beforeUnload: .beforeUnload(isReload: isReload)
        }
        let dialog = BrowserPageJavaScriptDialog(kind: pageKind, message: message, origin: URL(string: origin))
        pendingDialogs[token]?.cancel()
        pendingDialogs[token] = Task { @MainActor [weak self] in
            let response: BrowserPageJavaScriptDialogResponse
            if let self, let uiDelegate = self.uiDelegate {
                response = await uiDelegate.page(self, runJavaScriptDialog: dialog)
            } else {
                response = Self.defaultResponse(for: pageKind)
            }
            guard !Task.isCancelled, self?.pendingDialogs.removeValue(forKey: token) != nil else { return }
            switch response {
            case .accept(let text):
                CEFRuntime.shared.answerJSDialog(token: token, accept: true, text: text ?? "")
            case .dismiss:
                CEFRuntime.shared.answerJSDialog(token: token, accept: false)
            }
        }
    }

    nonisolated static func defaultResponse(for kind: BrowserPageJavaScriptDialog.Kind) -> BrowserPageJavaScriptDialogResponse {
        switch kind {
        case .alert, .beforeUnload: .accept(text: nil)
        case .confirm, .prompt: .dismiss
        }
    }

    /// A tab or popup Chromium created for this page (target=_blank,
    /// `window.open`). It already lives in this page's Chromium window with
    /// `window.opener` intact; the UI delegate hosts it or it closes.
    private func handleNewBrowser(_ popup: CEFBrowser, disposition: CEFDisposition, features: CGRect?, userGesture: Bool) {
        let route = ChromiumWindowOpenRoute.route(
            disposition: ChromiumWindowOpenDisposition(raw: Int(disposition.rawValue)),
            hasWindowFeatures: features != nil,
            userGesture: userGesture,
            hasOpener: true,
            hasURL: popup.state.url != nil
        )
        guard let uiDelegate,
              let placement = route.openRequestPlacement(
                  width: features.map { Double($0.width) },
                  height: features.map { Double($0.height) }
              ) else {
            popup.close()
            return
        }
        let request = BrowserPageOpenRequest(url: popup.state.url, placement: placement, isUserGesture: userGesture)
        switch uiDelegate.page(self, openNewPage: request) {
        case .allowPopup:
            let popupPage = CEFBrowserPage(browser: popup, shim: shimProvider, devToolsLayoutStore: devToolsLayoutStore)
            popupPage.rendererProcesses = rendererProcesses
            // An agent's page reaches its popups through window.opener and
            // window.open handles: they never fill a password either.
            if isAgentDriven { popupPage.markAgentDriven() }
            uiDelegate.page(self, didCreatePopup: popupPage, for: request)
        case .handled, .block:
            popup.close()
        }
    }

    /// Publishes the page's favicon as PNG data (`faviconChanged`): nil for
    /// no icon, else the image fetched through the page's request context.
    /// A reply for an icon the page has since replaced is ignored.
    private func updateFavicon(_ url: URL?) {
        guard let url, let browserID = browser.browserID else {
            if let browserID = browser.browserID { faviconFetcher.cancel(browserID: browserID) }
            emit(.faviconChanged(nil))
            return
        }
        faviconFetcher.fetch(url, browserID: browserID) { [weak self] png in
            guard let self, self.lastFaviconURL == url else { return }
            self.emit(.faviconChanged(png))
        }
    }

    func emit(_ event: BrowserPageEvent) {
        if let eventContinuation {
            eventContinuation.yield(event)
        } else if !isClosed, eventStream == nil {
            pendingEvents.append(event)
        }
    }

    // MARK: Mapping

    nonisolated static func pageState(_ state: CEFBrowserState) -> BrowserPageState {
        BrowserPageState(
            url: state.url,
            title: state.title.isEmpty ? nil : state.title,
            isLoading: state.isLoading,
            estimatedProgress: state.progress,
            canGoBack: state.canGoBack,
            canGoForward: state.canGoForward,
            pageZoom: state.zoom,
            hasOnlySecureContent: state.url?.scheme?.lowercased() == "https",
            isContentFullscreen: state.isFullscreen,
            processExit: state.rendererExit.map { processExit(status: $0.status, code: $0.code) },
            isUnresponsive: state.isUnresponsive
        )
    }

    /// Maps `cef_termination_status_t`.
    nonisolated static func processExit(status: Int, code: Int) -> BrowserPageProcessExit {
        let kind: BrowserPageProcessExit.Kind = switch status {
        case 1: .killed
        case 2: .crashed
        case 3: .outOfMemory
        case 4: .launchFailed
        default: .other
        }
        return BrowserPageProcessExit(kind: kind, status: Int32(clamping: code))
    }

    nonisolated static func engineError(_ error: CEFError) -> BrowserEngineError {
        switch error {
        case .unavailable(let reason): .unavailable(.chromium, reason.browserEngineReason)
        case .browserClosed: .pageClosed
        case .timedOut(let method): .javaScript("timed out: \(method)")
        case .devTools(let message): .javaScript(message)
        }
    }

    nonisolated static func inputCommands(for event: BrowserPageInputEvent) -> [(String, [String: Any])] {
        switch event {
        case .click(let point, let button, let clickCount, let modifiers):
            let base: [String: Any] = [
                "x": point.x, "y": point.y, "button": buttonName(button),
                "clickCount": clickCount, "modifiers": modifierBits(modifiers),
            ]
            var pressed = base
            pressed["type"] = "mousePressed"
            var released = base
            released["type"] = "mouseReleased"
            return [("Input.dispatchMouseEvent", pressed), ("Input.dispatchMouseEvent", released)]
        case .mouseMove(let point, let modifiers):
            return [("Input.dispatchMouseEvent", [
                "type": "mouseMoved", "x": point.x, "y": point.y, "modifiers": modifierBits(modifiers),
            ])]
        case .scroll(let point, let deltaX, let deltaY):
            return [("Input.dispatchMouseEvent", [
                "type": "mouseWheel", "x": point.x, "y": point.y, "deltaX": deltaX, "deltaY": deltaY,
            ])]
        case .key(let key, let modifiers):
            let bits = modifierBits(modifiers)
            var down: [String: Any] = ["type": "keyDown", "key": key, "modifiers": bits]
            if key.count == 1 { down["text"] = key }
            return [
                ("Input.dispatchKeyEvent", down),
                ("Input.dispatchKeyEvent", ["type": "keyUp", "key": key, "modifiers": bits]),
            ]
        case .insertText(let text):
            return [("Input.insertText", ["text": text])]
        }
    }

    private nonisolated static func buttonName(_ button: BrowserPageInputEvent.MouseButton) -> String {
        switch button {
        case .left: "left"
        case .right: "right"
        case .middle: "middle"
        }
    }

    /// CDP modifier bits: Alt 1, Ctrl 2, Meta 4, Shift 8.
    private nonisolated static func modifierBits(_ modifiers: BrowserPageInputEvent.Modifiers) -> Int {
        var bits = 0
        if modifiers.contains(.option) { bits |= 1 }
        if modifiers.contains(.control) { bits |= 2 }
        if modifiers.contains(.command) { bits |= 4 }
        if modifiers.contains(.shift) { bits |= 8 }
        return bits
    }

    nonisolated static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    nonisolated static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
