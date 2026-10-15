public import AppKit
import CoreGraphics
public import Foundation

/// How a Chromium page starts.
public struct CEFBrowserConfiguration: Sendable {
    /// The cmux browser profile; its store is `CEFProfileStorage.cachePath(for:)`.
    public var profile: UUID
    /// An in-memory store that is never written to disk.
    public var offTheRecord: Bool
    /// The request context key to use instead of the profile's own store
    /// (an absolute directory under the runtime's storage root, or an
    /// off-the-record key). Nil derives it from `profile`.
    public var contextKey: String?
    public var initialURL: URL?
    /// Page zoom factor (1 = 100 %).
    public var zoom: Double
    /// Chromium navigation state from `CEFBrowser.navigationState()`.
    public var restoreState: String?

    public init(profile: UUID, offTheRecord: Bool = false, contextKey: String? = nil, initialURL: URL? = nil,
                zoom: Double = 1, restoreState: String? = nil) {
        self.profile = profile
        self.offTheRecord = offTheRecord
        self.contextKey = contextKey
        self.initialURL = initialURL
        self.zoom = zoom
        self.restoreState = restoreState
    }
}

/// What a Chromium page shows now.
public struct CEFBrowserState: Equatable, Sendable {
    public var url: URL?
    public var title = ""
    public var isLoading = false
    public var canGoBack = false
    public var canGoForward = false
    /// 0...1
    public var progress: Double = 0
    public var faviconURL: URL?
    public var isFullscreen = false
    /// The renderer stopped handling input (hang monitor).
    public var isUnresponsive = false
    /// The renderer ended; cleared by the next load.
    public var rendererExit: CEFRendererExit?
    public var zoom: Double = 1

    public init() {}
}

/// A renderer that ended (Chromium's "Aw, Snap!").
public struct CEFRendererExit: Equatable, Sendable {
    /// `cef_termination_status_t`: 0 abnormal, 1 killed, 2 crashed, 3 out of memory, 4 launch failed, 5 integrity failure.
    public var status: Int
    /// Exit code or signal.
    public var code: Int
    public var message: String
}

/// What a Chromium page reports to its owner.
public enum CEFBrowserEvent {
    /// `CEFBrowser.state` changed.
    case stateChanged(CEFBrowserState)
    case loadStarted(URL?, fromPost: Bool)
    case loadFinished(httpStatus: Int)
    case loadFailed(code: Int, message: String, url: URL?, chromiumInterstitial: Bool)
    /// The page opened a tab or popup (target=_blank, window.open). It
    /// lives in this page's Chromium window until the owner shows its
    /// `hostView` somewhere (`window.opener` keeps working); close it to
    /// refuse it.
    case newBrowser(CEFBrowser, disposition: CEFDisposition, features: CGRect?, userGesture: Bool)
    /// The page asked to close (`window.close()`).
    case closeRequested
    /// Chromium destroyed the browser.
    case closed
    /// Every shim event of this browser, after the state update (feature
    /// code: context menus, permissions, downloads, DevTools).
    case shim(CEFShimEvent)
}

/// One Chromium page: a browser in a Chromium window of its own that tracks
/// `hostView`. Create it, put `hostView` in the view hierarchy, and the page
/// starts when the view first enters a window (or on `createNow()` for a page
/// no pane shows). Main thread only.
@MainActor
public final class CEFBrowser {
    public let configuration: CEFBrowserConfiguration
    /// The view the page window tracks; size and place it like a web view.
    public let hostView = CEFHostView()
    /// Chromium's browser id, nil until created and after it closed.
    public private(set) var browserID: Int32?
    public private(set) var state = CEFBrowserState()
    public private(set) var isClosed = false
    /// Receives this page's events.
    public var onEvent: (@MainActor (CEFBrowserEvent) -> Void)?
    /// Sees key downs before the page; return true to consume (app shortcuts).
    public var keyDownHandler: (@MainActor (NSEvent) -> Bool)?

    unowned let runtime: CEFRuntime
    private var pendingURL: URL?
    private var pendingRestore: String?
    private var pendingFocus = false
    private var isCreationPending = false
    var isGrantingFocus = false
    private var nextFindID: Int32 = 1
    /// A popup Chromium created in its opener's window, not moved yet.
    private var awaitsWindowMove = false
    /// The about:blank page that created this popup's own window.
    private var placeholder: CEFBrowser?
    private weak var placeholderOwner: CEFBrowser?
    /// This page only creates a popup's window (never shown as a page).
    private var isPlaceholder = false
    /// `.closed` was sent (once per page).
    private var sentClosed = false
    private weak var opener: CEFBrowser?

    public convenience init(configuration: CEFBrowserConfiguration) {
        self.init(configuration: configuration, runtime: .shared)
    }

    init(configuration: CEFBrowserConfiguration, runtime: CEFRuntime) {
        self.configuration = configuration
        self.runtime = runtime
        pendingURL = configuration.initialURL
        pendingRestore = configuration.restoreState
        state.zoom = configuration.zoom
        state.url = configuration.initialURL
        hostView.onPresentationChange = { [weak self] _ in self?.presentationChanged() }
    }

    /// A tab Chromium created for `opener` (already in the opener's window).
    init(adopting id: Int32, from opener: CEFBrowser, runtime: CEFRuntime) {
        var configuration = opener.configuration
        configuration.initialURL = nil
        configuration.restoreState = nil
        configuration.zoom = 1
        self.configuration = configuration
        self.runtime = runtime
        self.opener = opener
        awaitsWindowMove = true
        hostView.onPresentationChange = { [weak self] _ in self?.presentationChanged() }
    }

    /// The placeholder page that creates a popup's own window.
    private init(placeholderFor owner: CEFBrowser) {
        configuration = owner.configuration
        runtime = owner.runtime
        placeholderOwner = owner
        isPlaceholder = true
        pendingURL = URL(string: "about:blank")
    }

    /// The request context key of this page's store.
    public var contextKey: String {
        configuration.contextKey
            ?? runtime.storage.contextKey(for: configuration.profile, offTheRecord: configuration.offTheRecord)
    }

    // MARK: Lifetime

    private func presentationChanged() {
        guard !isClosed, hostView.isPresented else { return }
        if awaitsWindowMove {
            ensureOwnWindow()
        } else if browserID == nil {
            createNow()
        } else {
            reactivate()
            hostView.postGeometryChange()
        }
    }

    /// Creates the page now (starting CEF first when needed), also when
    /// `hostView` is in no window: a page an agent drives in the background.
    public func createNow() {
        guard !isClosed, browserID == nil, !isCreationPending, !awaitsWindowMove, !runtime.isShuttingDown else { return }
        guard runtime.isRunning else {
            isCreationPending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.runtime.start()
                } catch {
                    self.isCreationPending = false
                    self.creationFailed(String(describing: error))
                    return
                }
                self.isCreationPending = false
                self.createNow()
            }
            return
        }
        createWindow(in: hostView, url: initialURLString())
    }

    private func initialURLString() -> String {
        // An empty URL creates the browser without navigating, which
        // restoring a navigation state needs.
        if pendingRestore != nil { return "" }
        defer { pendingURL = nil }
        return pendingURL?.absoluteString ?? ""
    }

    private func createWindow(in view: CEFHostView, url: String) {
        guard let shim = runtime.shim, !runtime.isShuttingDown else { return creationFailed("CEF is not running") }
        let key = contextKey
        if !configuration.offTheRecord, key.hasPrefix("/") {
            // CEF refuses a request context whose cache directory is missing.
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: key), withIntermediateDirectories: true)
        }
        let request = runtime.makeRequestToken()
        let bounds = view.bounds.size
        let size = bounds.width >= 1 && bounds.height >= 1 ? bounds : NSSize(width: 1280, height: 800)
        if view.window == nil, view.bounds.size != size { view.setFrameSize(size) }
        isCreationPending = true
        runtime.pendingWindows[request] = self
        runtime.contextOpened(key)
        let started = shim.createWindow(
            request, Unmanaged.passUnretained(view).toOpaque(),
            Int32(clamping: Int(size.width.rounded())), Int32(clamping: Int(size.height.rounded())),
            url, key
        )
        if started != 1 {
            runtime.pendingWindows[request] = nil
            isCreationPending = false
            if isPlaceholder {
                placeholderOwner?.placeholderFailed()
            } else {
                creationFailed("Chromium could not create the page")
            }
        }
    }

    private func creationFailed(_ message: String) {
        emit(.loadFailed(code: -1, message: message, url: state.url, chromiumInterstitial: false))
    }

    func attach(id: Int32) {
        browserID = id
        isCreationPending = false
    }

    /// The window this page created exists (OnAfterCreated of its request).
    func windowCreated() {
        if isPlaceholder {
            // Its popup closed meanwhile (or was freed): nothing moves in.
            guard let owner = placeholderOwner, !owner.isClosed else { return close() }
            owner.placeholderReady()
            return
        }
        guard let id = browserID, let shim = runtime.shim else { return }
        // Closed while Chromium was still creating it: close it now.
        if isClosed {
            shim.close(id)
            return
        }
        if state.zoom != 1 { shim.setZoomLevel(id, Self.zoomLevel(forFactor: state.zoom)) }
        if let restore = pendingRestore {
            pendingRestore = nil
            let restored = restore.withCString { shim.tabRestoreNavigation(id, $0) }
            if restored != 1, let url = configuration.initialURL { shim.loadURL(id, url.absoluteString) }
        } else if let url = pendingURL {
            pendingURL = nil
            shim.loadURL(id, url.absoluteString)
        }
        if pendingFocus, hostView.isPresented { grantFocus(id) }
    }

    /// Shows this page's tab in its window again (a popup Chromium inserted
    /// took the active tab).
    func reactivate() {
        guard let id = browserID, !awaitsWindowMove else { return }
        _ = runtime.shim?.tabActivate(id)
    }

    /// A popup shown for the first time: its own window is created with an
    /// about:blank placeholder, the popup moves into it (`cmux_tab_move_to_window`
    /// keeps the WebContents, so `window.opener` keeps working), and the
    /// placeholder closes.
    private func ensureOwnWindow() {
        guard placeholder == nil, runtime.isRunning else { return }
        let blank = CEFBrowser(placeholderFor: self)
        placeholder = blank
        blank.createWindow(in: hostView, url: "about:blank")
    }

    private func placeholderReady() {
        guard let blank = placeholder else { return }
        placeholder = nil
        defer { blank.close() }
        guard let shim = runtime.shim, let anchor = blank.browserID, let id = browserID, !isClosed else { return }
        if shim.tabMoveToWindow(id, anchor, -1) == 1 {
            awaitsWindowMove = false
            _ = shim.tabActivate(id)
            hostView.postGeometryChange()
            opener?.reactivate()
        } else {
            runtime.logger.error("CEF popup \(id) could not move into its own window; closing it")
            close()
        }
    }

    /// The placeholder could not create a window: a later presentation retries.
    private func placeholderFailed() {
        placeholder = nil
    }

    func browserDidClose() {
        browserID = nil
        isClosed = true
        if !isPlaceholder { emitClosedOnce() }
    }

    private func emitClosedOnce() {
        guard !sentClosed else { return }
        sentClosed = true
        emit(.closed)
    }

    /// Closes the page (idempotent). `.closed` follows once Chromium
    /// destroyed it.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        if let id = browserID {
            runtime.shim?.close(id)
        } else if !isPlaceholder {
            // Not created yet (a pending creation closes in windowCreated).
            emitClosedOnce()
        }
    }

    // MARK: Navigation

    public func load(_ url: URL) {
        state.rendererExit = nil
        if let id = browserID, !isClosed {
            runtime.shim?.loadURL(id, url.absoluteString)
        } else {
            pendingURL = url
            state.url = url
            emit(.stateChanged(state))
        }
    }

    public func goBack() { browserID.map { runtime.shim?.goBack($0) } }
    public func goForward() { browserID.map { runtime.shim?.goForward($0) } }
    public func reload() { browserID.map { runtime.shim?.reload($0) } }
    public func stop() { browserID.map { runtime.shim?.stop($0) } }

    /// Chromium's navigation state for `CEFBrowserConfiguration.restoreState`.
    public func navigationState() -> String? {
        guard let id = browserID, let shim = runtime.shim else { return nil }
        return shim.takeString(shim.tabNavigationState(id))
    }

    // MARK: Presentation

    /// Gives the page keyboard focus (only cmux focuses pages; Chromium's
    /// own focus requests are refused).
    public func setFocused(_ focused: Bool) {
        pendingFocus = focused
        guard let id = browserID else { return }
        if focused {
            guard hostView.isPresented else { return }
            grantFocus(id)
        } else {
            runtime.shim?.setFocus(id, 0)
        }
    }

    private func grantFocus(_ id: Int32) {
        isGrantingFocus = true
        defer { isGrantingFocus = false }
        runtime.shim?.setFocus(id, 1)
    }

    public func setZoom(_ factor: Double) {
        state.zoom = factor
        browserID.map { runtime.shim?.setZoomLevel($0, Self.zoomLevel(forFactor: factor)) }
        emit(.stateChanged(state))
    }

    /// Chromium zoom levels are logarithmic: factor = 1.2 ^ level.
    nonisolated static func zoomLevel(forFactor factor: Double) -> Double {
        guard factor > 0 else { return 0 }
        return log(factor) / log(1.2)
    }

    /// Answers a renderer hang: true ends the renderer.
    public func answerUnresponsive(terminate: Bool) {
        guard let id = browserID else { return }
        _ = runtime.shim?.unresponsiveReply(id, terminate ? 1 : 0)
    }

    // MARK: Find

    /// Starts or continues a find; results arrive as `.shim(.findResult)`
    /// with the returned id.
    @discardableResult
    public func find(_ text: String, forward: Bool = true, matchCase: Bool = false, findNext: Bool = false) -> Int32 {
        let findID = nextFindID
        nextFindID &+= 1
        if let id = browserID { runtime.shim?.find(id, findID, text, forward ? 1 : 0, matchCase ? 1 : 0, findNext ? 1 : 0) }
        return findID
    }

    public func stopFinding(clearSelection: Bool = true) {
        browserID.map { runtime.shim?.stopFinding($0, clearSelection ? 1 : 0) }
    }

    // MARK: DevTools

    /// Opens Chromium's DevTools for the page (Chromium places it).
    public func showDevTools() {
        guard let id = browserID else { return }
        _ = runtime.shim?.devToolsCommand(id, CEFShimLibrary.DevToolsCommand.show.rawValue, 0, 0)
    }

    public func closeDevTools() {
        guard let id = browserID else { return }
        _ = runtime.shim?.devToolsCommand(id, CEFShimLibrary.DevToolsCommand.close.rawValue, 0, 0)
    }

    /// Runs a DevTools protocol method in process; returns its result JSON.
    public func devTools(method: String, paramsJSON: String = "{}",
                         timeout: Duration = CEFRuntime.devToolsTimeout) async throws -> String {
        guard let id = browserID, !isClosed else { throw CEFError.browserClosed }
        return try await runtime.devTools(id, method: method, paramsJSON: paramsJSON, timeout: timeout)
    }

    /// Evaluates `script` in the page's main world (`Runtime.evaluate`,
    /// promises awaited) and returns the value as Foundation JSON objects:
    /// nil for undefined, NSNull for null.
    public func evaluateJavaScript(_ script: String) async throws -> Any? {
        let params = Self.json(["expression": script, "returnByValue": true, "awaitPromise": true])
        let result = try await devTools(method: "Runtime.evaluate", paramsJSON: params)
        return try Self.evaluationValue(result)
    }

    nonisolated static func evaluationValue(_ json: String) throws -> Any? {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CEFError.devTools("invalid DevTools result")
        }
        if let details = object["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            throw CEFError.devTools(exception?["description"] as? String ?? details["text"] as? String ?? "exception")
        }
        guard let result = object["result"] as? [String: Any] else { return nil }
        if (result["type"] as? String) == "undefined" { return nil }
        return result["value"] ?? NSNull()
    }

    nonisolated static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: Events

    func emit(_ event: CEFBrowserEvent) {
        onEvent?(event)
    }

    func handle(_ event: CEFShimEvent) {
        if isPlaceholder || isClosed { return }
        var changed = true
        switch event {
        case .address(_, let url):
            state.url = URL(string: url)
        case .title(_, let title):
            state.title = title
        case .favicon(_, let url):
            state.faviconURL = url.isEmpty ? nil : URL(string: url)
        case .loadingState(_, let loading, let back, let forward):
            state.isLoading = loading
            state.canGoBack = back
            state.canGoForward = forward
        case .progress(_, let value):
            state.progress = value
        case .fullscreen(_, let entering):
            state.isFullscreen = entering
        case .renderTerminated(_, let status, let code, let text):
            state.rendererExit = CEFRendererExit(status: status, code: code, message: text)
            state.isLoading = false
        case .renderUnresponsive:
            state.isUnresponsive = true
        case .renderResponsive:
            state.isUnresponsive = false
        case .loadStart(_, let url, let fromPost):
            state.rendererExit = nil
            emit(.loadStarted(URL(string: url), fromPost: fromPost))
            changed = false
        case .loadEnd(_, let status):
            emit(.loadFinished(httpStatus: status))
            changed = false
        case .loadError(_, let code, let text, let url, let interstitial):
            emit(.loadFailed(code: code, message: text, url: URL(string: url), chromiumInterstitial: interstitial))
            changed = false
        case .closeRequested:
            emit(.closeRequested)
            changed = false
        default:
            changed = false
        }
        if changed { emit(.stateChanged(state)) }
        emit(.shim(event))
    }
}
