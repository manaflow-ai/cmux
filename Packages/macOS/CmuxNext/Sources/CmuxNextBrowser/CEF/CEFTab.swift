public import AppKit
public import Foundation
public import Observation

/// A Chromium tab (CEF fork, Chrome style). Its page is a child window that
/// tracks `contentView` (`.childWindow` presentation). The Chromium browser
/// is created the first time the tab is shown, so hidden background tabs
/// cost nothing until selected.
@Observable
public final class CEFTab: BrowserTab, BrowserOcclusionHosting, BrowserExtensionActionHosting, BrowserDevToolsHosting, BrowserHangAnswering {
    public let id: BrowserTabID
    public let engineKind: BrowserEngineKind = .cef
    public let profileID: BrowserProfileID
    public let presentation: BrowserPresentation = .childWindow

    public var state: BrowserTabState { machine.state }
    public internal(set) var favicon: NSImage?
    public let pendingPrompts: [BrowserPrompt] = []
    public internal(set) var extensionActions: [CEFExtensionAction] = []
    public internal(set) var openExtensionPopup: String?
    @ObservationIgnored public var extensionActionAnchor: ((String) -> CGRect?)?

    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?
    /// Permission use of the current document (Page Info).
    @ObservationIgnored public let pageInfoActivity = PageInfoActivity()

    /// Chromium browser identifier once created.
    @ObservationIgnored public private(set) var browserID: Int32?

    /// Rects in `contentView` coordinates where native UI covers the page.
    public var occlusionRects: [CGRect] = [] {
        didSet { applyOcclusion() }
    }

    /// DevTools of this page (docked in `contentView` or in a window).
    public internal(set) var devTools: BrowserDevToolsState
    @ObservationIgnored var devToolsLayout: CEFDevToolsLayout
    @ObservationIgnored var devToolsBrowserID: Int32?
    /// Between `DEVTOOLS_WILL_OPEN` and `OPENED`: the layout keeps room.
    @ObservationIgnored var devToolsOpening = false
    /// Runs once DevTools closed (a move into or out of a window reopens).
    @ObservationIgnored var devToolsAfterClose: BrowserDevToolsCommand?
    /// The docked DevTools' parent view and the divider, while docked.
    @ObservationIgnored var devToolsViews: (host: CEFHostView, divider: CEFDevToolsDivider)?
    @ObservationIgnored public weak var devToolsObserver: (any BrowserDevToolsObserving)?

    var machine = BrowserTabStateMachine()
    @ObservationIgnored var isCreationPending = false
    @ObservationIgnored var navigation: BrowserNavigationID?
    @ObservationIgnored var nextNavigation: UInt64 = 0
    @ObservationIgnored var pendingURL: URL?
    @ObservationIgnored var pendingFocus = false
    /// The renderer ended while the tab was hidden: reload when shown
    /// (Chrome reloads a crashed background tab when it is selected).
    @ObservationIgnored var reloadWhenShown = false
    @ObservationIgnored var findContinuation: CheckedContinuation<BrowserFindResult, Never>?
    @ObservationIgnored var nextFindID: Int32 = 1
    @ObservationIgnored var faviconTask: Task<Void, Never>?
    @ObservationIgnored private(set) var isClosed = false
    @ObservationIgnored private var isOccluded = false
    @ObservationIgnored let host: CEFPaneHost
    @ObservationIgnored unowned let runtime: CEFRuntime
    @ObservationIgnored lazy var container: CEFTabContentView = {
        let view = CEFTabContentView()
        view.tab = self
        return view
    }()

    init(id: BrowserTabID, profile: BrowserProfileID, host: CEFPaneHost, runtime: CEFRuntime) {
        self.id = id
        self.profileID = profile
        self.host = host
        self.runtime = runtime
        let layout = CEFDevToolsLayout.remembered
        devToolsLayout = layout
        devTools = BrowserDevToolsState(dock: layout.dock)
    }

    public var contentView: NSView { container }

    var initialURLString: String { pendingURL?.absoluteString ?? "about:blank" }

    // MARK: Lifetime (called by CEFPaneHost / CEFRuntime)

    func attach(browser: Int32) {
        browserID = browser
        isCreationPending = false
        let zoom = machine.state.zoom
        if zoom != 1 { runtime.shim?.setZoomLevel(browser, CEFZoom.level(forFactor: zoom)) }
        if pendingFocus { runtime.shim?.setFocus(browser, 1) }
        refreshExtensionActions()
    }

    func creationFailed() {
        isCreationPending = false
        let error = BrowserLoadError(domain: "CEF", code: -1, message: Strings.cefUnavailable, failingURL: pendingURL)
        let id = makeNavigationID()
        machine.apply(.started(id, url: pendingURL))
        machine.apply(.failed(id, error))
    }

    func browserDidClose() {
        browserID = nil
        findContinuation?.resume(returning: .none)
        findContinuation = nil
        host.removed(self)
        if !isClosed {
            isClosed = true
            emit(.close)
        }
    }

    func contentDidAppear(in view: CEFTabContentView) {
        guard !isClosed else { return }
        host.present(self, in: view)
        view.layoutContent()
        if reloadWhenShown {
            reloadWhenShown = false
            if state.processExit != nil { reload() }
        }
    }

    /// The renderer ended (crash, kill, out of memory, launch failure). The
    /// pane shows the sad tab; a hidden tab reloads when it is shown.
    func rendererTerminated(_ exit: BrowserProcessExit) {
        guard !isClosed else { return }
        machine.apply(.processExited(exit))
        reloadWhenShown = host.visibleTab !== self
        findContinuation?.resume(returning: .none)
        findContinuation = nil
        runtime.recordRendererExit(exit, tab: self)
    }

    func contentDidDisappear() {
        host.conceal(self)
    }

    func emit(_ intent: BrowserTabIntent) {
        delegate?.browserTab(self, didRequest: intent)
    }

    func inheritDelegates(from opener: CEFTab?) {
        delegate = opener?.delegate
        keyRouter = opener?.keyRouter
        devToolsObserver = opener?.devToolsObserver
    }

    func makeNavigationID() -> BrowserNavigationID {
        nextNavigation += 1
        return BrowserNavigationID(rawValue: nextNavigation)
    }

    // MARK: BrowserTab

    public func load(_ url: URL) {
        guard !isClosed else { return }
        let id = makeNavigationID()
        navigation = id
        machine.apply(.started(id, url: url))
        if let browserID {
            runtime.shim?.loadURL(browserID, url.absoluteString)
        } else {
            pendingURL = url
        }
    }

    public func goBack() { browserID.map { runtime.shim?.goBack($0) } }
    public func goForward() { browserID.map { runtime.shim?.goForward($0) } }

    public func reload() {
        reloadWhenShown = false
        guard let browserID else {
            if let url = pendingURL ?? state.url { load(url) }
            return
        }
        guard state.processExit != nil, let url = state.url else {
            runtime.shim?.reload(browserID)
            return
        }
        // The sad tab clears now, not when the new renderer's first callback
        // arrives. Loading the shown URL (Chromium turns a load of the
        // current entry's URL into a reload, so history is kept) also covers
        // a crash before the load committed.
        let id = makeNavigationID()
        navigation = id
        machine.apply(.started(id, url: url))
        runtime.shim?.loadURL(browserID, url.absoluteString)
    }

    /// Answers "Page unresponsive": wait restarts Chromium's hang timer,
    /// terminate ends the renderer (the sad tab follows).
    public func answerUnresponsivePage(terminate: Bool) {
        guard state.isUnresponsive else { return }
        if let browserID { _ = runtime.shim?.unresponsiveReply(browserID, terminate ? 1 : 0) }
        if !terminate { machine.apply(.unresponsiveChanged(false)) }
    }

    public func stop() {
        browserID.map { runtime.shim?.stop($0) }
        machine.apply(.stopped)
    }

    public func setFocused(_ focused: Bool) {
        pendingFocus = focused
        browserID.map { runtime.shim?.setFocus($0, focused ? 1 : 0) }
    }

    public func setOccluded(_ occluded: Bool) async {
        guard occluded != isOccluded else { return }
        isOccluded = occluded
        if occluded {
            let image = try? await snapshot()
            guard isOccluded else { return }
            container.showSnapshot(image)
            if host.visibleTab === self { host.hostView.isHidden = true }
            devToolsViews?.host.isHidden = true
        } else {
            if host.visibleTab === self { host.hostView.isHidden = false }
            devToolsViews?.host.isHidden = false
            container.showSnapshot(nil)
        }
    }

    public func snapshot() async throws -> CGImage {
        guard let browserID, !isClosed else { throw BrowserTabError.snapshotUnavailable }
        let json = try await runtime.devTools(browserID, method: "Page.captureScreenshot", params: ["format": "png"])
        return try CEFDevToolsResult.screenshot(json)
    }

    public func setZoom(_ zoom: Double) {
        machine.apply(.zoomChanged(zoom))
        browserID.map { runtime.shim?.setZoomLevel($0, CEFZoom.level(forFactor: zoom)) }
    }

    public func exitContentFullscreen() {
        guard state.isContentFullscreen else { return }
        Task { _ = try? await evaluate("document.exitFullscreen && document.exitFullscreen()") }
    }

    public func showDevTools() { performDevTools(.show) }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        faviconTask?.cancel()
        if let browserID {
            runtime.shim?.close(browserID)
        } else {
            host.removed(self)
        }
        container.removeFromSuperview()
    }
}
