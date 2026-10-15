public import AppKit
public import Foundation

/// One live page in a browser panel, independent of the engine that renders it.
///
/// A browser panel owns exactly one page at a time. The panel hosts
/// ``contentView``, drives the page through this protocol, and is the single
/// consumer of ``events``; it mirrors page state into its own published
/// properties, which the browser chrome reads.
///
/// JavaScript results are Foundation JSON objects (`NSString`, `NSNumber`,
/// `NSArray`, `NSDictionary`, `NSNull`) or `nil`, the shapes `WKWebView`
/// returns, so automation and find code runs unchanged on every engine.
///
/// Optional features are gated by ``capabilities``; calling an unsupported
/// operation throws ``BrowserEngineError/unsupported(_:)`` or does nothing.
///
/// ```swift
/// let page = try registry.makePage(.chromium, BrowserPageConfiguration(panelID: id, profileID: profile))
/// container.addSubview(page.contentView)
/// page.load(URLRequest(url: url))
/// let title = try await page.evaluateJavaScript("document.title", in: .page) as? String
/// ```
@MainActor
public protocol BrowserPage: AnyObject, BrowserFindScriptEvaluating {
    /// The engine that renders this page.
    var engineKind: BrowserEngineKind { get }
    /// The features this page supports.
    var capabilities: BrowserEngineCapabilities { get }
    /// How the page puts pixels on screen.
    var presentation: BrowserPagePresentation { get }
    /// The view the panel places in its pane.
    var contentView: NSView { get }

    /// The current page state.
    var state: BrowserPageState { get }
    /// Page events. A page has one consumer, its panel: every read returns
    /// the same single-consumer stream, so iterating it from two tasks at
    /// once is a programmer error. The stream finishes when the page closes.
    var events: AsyncStream<BrowserPageEvent> { get }
    /// The app's decision handler. Conformers hold it weakly.
    var uiDelegate: (any BrowserPageUIDelegate)? { get set }

    // MARK: Navigation

    /// Starts loading a request in the main frame.
    /// - Parameter request: The request to load.
    func load(_ request: URLRequest)
    /// Loads an HTML string as the main document.
    /// - Parameters:
    ///   - html: The document source.
    ///   - baseURL: The URL relative references resolve against.
    func loadHTMLString(_ html: String, baseURL: URL?)
    /// Goes one entry back in history, if possible.
    func goBack()
    /// Goes one entry forward in history, if possible.
    func goForward()
    /// Reloads the current page, using caches.
    func reload()
    /// Reloads the current page, bypassing caches.
    func reloadFromOrigin()
    /// Stops loading.
    func stop()

    // MARK: JavaScript

    /// Evaluates a script and returns its completion value.
    /// - Parameters:
    ///   - script: The JavaScript source.
    ///   - world: The world to run in.
    /// - Returns: The completion value as Foundation JSON objects, or `nil`
    ///   for `undefined`.
    /// - Throws: The engine's evaluation error: WebKit's `WKError`, or
    ///   ``BrowserEngineError/javaScript(_:)`` from engines without their own.
    func evaluateJavaScript(_ script: String, in world: BrowserPageScriptWorld) async throws -> Any?

    /// Runs `body` as the body of an async function and returns what it
    /// resolves to.
    /// - Parameters:
    ///   - body: The function body; it may `await` and must `return` a value.
    ///   - arguments: Values bound to local names of the same keys. Values
    ///     must be JSON-compatible.
    ///   - world: The world to run in.
    /// - Returns: The resolved value as Foundation JSON objects, or `nil`.
    /// - Throws: The engine's evaluation error on rejection, as
    ///   ``evaluateJavaScript(_:in:)``.
    func callAsyncJavaScript(
        _ body: String,
        arguments: [String: any Sendable],
        in world: BrowserPageScriptWorld
    ) async throws -> Any?

    /// Injects a script into every document the page loads from now on.
    /// - Parameter script: The script.
    func addUserScript(_ script: BrowserPageUserScript)
    /// Removes every script added with ``addUserScript(_:)``.
    func removeAllUserScripts()

    // MARK: Zoom, devtools, snapshot

    /// Page zoom, `1` is 100%.
    var pageZoom: Double { get set }

    /// `true` while the developer tools are open.
    var isDevToolsVisible: Bool { get }
    /// Opens the developer tools.
    func showDevTools()
    /// Closes the developer tools.
    func closeDevTools()
    /// Sends a Chrome DevTools Protocol command and returns its JSON result.
    /// - Parameters:
    ///   - method: The CDP method, for example `Page.captureScreenshot`.
    ///   - params: The JSON-encoded params object, or `nil`.
    /// - Returns: The JSON-encoded result object.
    /// - Throws: ``BrowserEngineError/unsupported(_:)`` without
    ///   ``BrowserEngineCapabilities/devToolsProtocol``.
    func sendDevToolsProtocolMessage(method: String, params: Data?) async throws -> Data

    /// Captures page pixels.
    /// - Parameter rect: The area in view coordinates, or `nil` for the visible page.
    /// - Returns: The captured image.
    /// - Throws: When the page cannot be captured now.
    func takeSnapshot(rect: CGRect?) async throws -> NSImage

    // MARK: Input, focus, visibility

    /// Gives keyboard focus to the page, or takes it away.
    /// - Parameter focused: `true` to focus the page.
    /// - Returns: `true` when the focus change took effect.
    @discardableResult
    func setFocused(_ focused: Bool) -> Bool
    /// Shows or hides the page. Hidden pages may throttle timers and media.
    /// - Parameter visible: `true` when the page is on screen.
    func setContentVisible(_ visible: Bool)
    /// Delivers a trusted input event.
    /// - Parameter event: The event.
    /// - Throws: ``BrowserEngineError/unsupported(_:)`` without
    ///   ``BrowserEngineCapabilities/trustedInput``.
    func dispatchInput(_ event: BrowserPageInputEvent) async throws

    // MARK: Media, restore, teardown

    /// `true` while page audio is muted.
    var isMuted: Bool { get set }
    /// Answers an unresponsive page (``BrowserPageEvent/unresponsiveChanged(_:)``).
    /// - Parameter terminate: `true` ends the page's content process; `false`
    ///   keeps waiting.
    func answerUnresponsive(terminate: Bool)
    /// The back/forward history with page state, for restoring later.
    /// - Returns: The state, or `nil` when the engine cannot export it now.
    func exportRestoreState() -> BrowserPageRestoreState?
    /// Tears the page down and finishes ``events``. Idempotent.
    func close()
}

extension BrowserPage {
    /// Engines that never report an unresponsive page have nothing to answer.
    /// - Parameter terminate: Ignored.
    public func answerUnresponsive(terminate: Bool) {}

    /// Runs a find-in-page script in the page world, so the shared find
    /// service works on every engine.
    /// - Parameter script: The find script.
    /// - Returns: The script's completion value.
    /// - Throws: The engine's evaluation error.
    public func evaluate(_ script: BrowserFindScript) async throws -> Any? {
        try await evaluateJavaScript(script.source, in: .page)
    }

    /// Evaluates a script in the page world.
    /// - Parameter script: The JavaScript source.
    /// - Returns: The completion value as Foundation JSON objects, or `nil`.
    /// - Throws: The engine's evaluation error.
    public func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await evaluateJavaScript(script, in: .page)
    }
}
