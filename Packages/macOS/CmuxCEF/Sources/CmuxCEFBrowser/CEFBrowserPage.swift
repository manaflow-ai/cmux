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
    /// The app's decision handler, held weakly.
    public weak var uiDelegate: (any BrowserPageUIDelegate)?

    private var eventStream: AsyncStream<BrowserPageEvent>?
    private var eventContinuation: AsyncStream<BrowserPageEvent>.Continuation?
    private var pendingEvents: [BrowserPageEvent] = []
    private var userScriptIdentifiers: [String] = []
    private var devToolsVisible = false
    private var muted = false
    private var lastFaviconURL: URL?
    private var isClosed = false

    /// The capabilities of every Chromium page.
    public static let engineCapabilities: BrowserEngineCapabilities = [
        .devTools, .devToolsProtocol, .trustedInput, .snapshots, .paneFullscreen,
        .crossOriginFrames, .userScripts, .findMatchCount,
    ]

    /// The page's extension side (toolbar actions, extension calls); nil
    /// when the engine was created without extension support.
    public let extensionSupport: CEFExtensionPageSupport?

    /// Wraps a CEF browser and starts receiving its events.
    /// - Parameters:
    ///   - browser: The Chromium page.
    ///   - extensions: The engine's extension stores, or nil for a page without extensions.
    public init(browser: CEFBrowser, extensions: CEFExtensionStores? = nil) {
        self.browser = browser
        extensionSupport = extensions.map { stores in
            CEFExtensionPageSupport(profileID: browser.configuration.profile, stores: stores) { [weak browser] in
                browser?.browserID
            }
        }
        browser.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    /// Always ``BrowserEngineKind/chromium``.
    public var engineKind: BrowserEngineKind { .chromium }

    /// Chromium's features.
    public var capabilities: BrowserEngineCapabilities { Self.engineCapabilities }

    /// Chromium draws in a window of its own that tracks ``contentView``.
    public var presentation: BrowserPagePresentation { .childWindow }

    /// The view the Chromium window tracks.
    public var contentView: NSView { browser.hostView }

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
    }

    /// Loads an HTML document as a `data:` URL.
    /// - Parameters:
    ///   - html: The document source.
    ///   - baseURL: Ignored; a `data:` document has no base URL.
    public func loadHTMLString(_ html: String, baseURL: URL?) {
        let encoded = Data(html.utf8).base64EncodedString()
        guard let url = URL(string: "data:text/html;charset=utf-8;base64,\(encoded)") else { return }
        browser.load(url)
    }

    /// Goes back.
    public func goBack() { browser.goBack() }
    /// Goes forward.
    public func goForward() { browser.goForward() }
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
        var source = script.source
        if script.injectionTime == .documentEnd {
            source = "document.addEventListener('DOMContentLoaded', () => {\n\(source)\n}, { once: true });"
        }
        if script.isMainFrameOnly {
            source = "if (window === window.top) {\n\(source)\n}"
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

    /// Removes every script added with ``addUserScript(_:)``.
    public func removeAllUserScripts() {
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

    /// Opens Chromium's DevTools.
    public func showDevTools() { browser.showDevTools() }

    /// Closes Chromium's DevTools.
    public func closeDevTools() { browser.closeDevTools() }

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

    /// The Chromium window follows ``contentView``'s presentation, so the
    /// host view's window membership already shows or hides it.
    /// - Parameter visible: Ignored.
    public func setContentVisible(_ visible: Bool) {}

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
        browser.close()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: Events

    private func handle(_ event: CEFBrowserEvent) {
        switch event {
        case .stateChanged(let cefState):
            extensionSupport?.noteBrowserID()
            emit(.stateChanged(Self.pageState(cefState)))
            if cefState.faviconURL != lastFaviconURL {
                lastFaviconURL = cefState.faviconURL
                if cefState.faviconURL == nil { emit(.faviconChanged(nil)) }
            }
        case .loadStarted(let url, _):
            emit(.navigationStarted(url))
        case .loadFinished:
            emit(.navigationFinished(browser.state.url))
        case .loadFailed(let code, let message, let url, _):
            emit(.navigationFailed(url, code: code, message: message))
        case .newBrowser(let popup, _, _, _):
            // Popups are not hosted yet; refuse them rather than leave a
            // hidden page running.
            popup.close()
        case .closeRequested:
            emit(.closeRequested)
        case .closed:
            eventContinuation?.finish()
        case .shim(let shimEvent):
            handle(shimEvent)
        }
    }

    private func handle(_ event: CEFShimEvent) {
        switch event {
        case .devToolsOpened:
            devToolsVisible = true
            emit(.devToolsVisibilityChanged(true))
        case .devToolsClosed:
            devToolsVisible = false
            emit(.devToolsVisibilityChanged(false))
        case .fullscreen(_, let entering):
            emit(.contentFullscreenChanged(entering))
        case .renderTerminated(_, let status, let code, _):
            emit(.processTerminated(Self.processExit(status: status, code: code)))
        case .renderUnresponsive:
            emit(.unresponsiveChanged(true))
        case .renderResponsive:
            emit(.unresponsiveChanged(false))
        default:
            break
        }
    }

    private func emit(_ event: BrowserPageEvent) {
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
