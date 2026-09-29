public import AppKit
public import Foundation
public import Observation

/// A Chromium tab (CEF fork, Chrome style). Its page is a child window that
/// tracks `contentView` (`.childWindow` presentation). The Chromium browser
/// is created the first time the tab is shown, so hidden background tabs
/// cost nothing until selected.
@Observable
public final class CEFTab: BrowserTab, BrowserOcclusionHosting, BrowserExtensionActionHosting {
    public let id: BrowserTabID
    public let engineKind: BrowserEngineKind = .cef
    public let profileID: BrowserProfileID
    public let presentation: BrowserPresentation = .childWindow

    public var state: BrowserTabState { machine.state }
    public internal(set) var favicon: NSImage?
    public let pendingPrompts: [BrowserPrompt] = []
    public internal(set) var extensionActions: [CEFExtensionAction] = []

    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?

    /// Chromium browser identifier once created.
    @ObservationIgnored public private(set) var browserID: Int32?

    public var occlusionRects: [CGRect] = [] {
        didSet { if host.visibleTab === self { host.hostView.occlusionRects = occlusionRects } }
    }

    var machine = BrowserTabStateMachine()
    @ObservationIgnored var isCreationPending = false
    @ObservationIgnored var navigation: BrowserNavigationID?
    @ObservationIgnored var nextNavigation: UInt64 = 0
    @ObservationIgnored var pendingURL: URL?
    @ObservationIgnored var pendingFocus = false
    @ObservationIgnored var findContinuation: CheckedContinuation<BrowserFindResult, Never>?
    @ObservationIgnored var nextFindID: Int32 = 1
    @ObservationIgnored var faviconTask: Task<Void, Never>?
    @ObservationIgnored private(set) var isClosed = false
    @ObservationIgnored private var isOccluded = false
    @ObservationIgnored let host: CEFPaneHost
    @ObservationIgnored unowned let runtime: CEFRuntime
    @ObservationIgnored private lazy var container: CEFTabContentView = {
        let view = CEFTabContentView()
        view.tab = self
        return view
    }()

    init(id: BrowserTabID, profile: BrowserProfileID, host: CEFPaneHost, runtime: CEFRuntime) {
        self.id = id
        self.profileID = profile
        self.host = host
        self.runtime = runtime
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
        host.hostView.occlusionRects = occlusionRects
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
        if let browserID { runtime.shim?.reload(browserID) } else if let url = pendingURL ?? state.url { load(url) }
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
        } else {
            if host.visibleTab === self { host.hostView.isHidden = false }
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

    public func showDevTools() { browserID.map { runtime.shim?.showDevTools($0) } }

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
