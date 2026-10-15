public import AppKit
public import CmuxBrowser
public import CmuxCEF

/// DevTools, find, zoom and the context menu of one Chromium page, wired to the engine-neutral
/// CmuxBrowser models. A CEF page owns one and forwards its shim events here.
///
/// The page and its docked DevTools are Chromium child windows over host views, so anything
/// drawn above them must be a hole in those windows: the divider's grab area always is, and the
/// panel's overlays (find bar, notices) arrive through ``chromeOcclusionRects``.
///
/// ```swift
/// let features = CEFPageFeatures(shim: CEFShimPageFeatures(library: shim),
///                                browserID: { [weak browser] in browser?.browserID },
///                                pageView: browser.hostView, layoutStore: store)
/// contentView = features.paneView                    // page + docked DevTools + divider
/// browser.onEvent = { if case .shim(let event) = $0 { features.handle(event) } }
/// ```
@MainActor
public final class CEFPageFeatures {
    /// Native find for the panel's find bar (``BrowserPageNativeFinding``).
    public let nativeFind: BrowserNativeFindSession
    /// The page's in-pane DevTools (``BrowserPageDevToolsHosting``).
    public let devTools: BrowserDevToolsPaneController
    /// The view the page hands its panel: page plus docked DevTools.
    public let paneView: BrowserDevToolsPaneView
    /// Adds and runs cmux context menu rows; without one, Chromium's own rows show alone.
    public weak var contextMenuHost: (any BrowserContextMenuHosting)?
    /// Rects of native UI over the page (find bar, notices), in ``paneView`` coordinates
    /// (``BrowserPageOcclusionHosting/pageOcclusionRects``).
    public var chromeOcclusionRects: [CGRect] = [] {
        didSet {
            guard chromeOcclusionRects != oldValue else { return }
            applyOcclusion()
        }
    }

    private let shim: any CEFPageFeatureShim
    private let browserID: @MainActor () -> Int32?
    private let pageHostView: CEFHostView
    /// Held here: the DevTools controller keeps its driver weakly.
    private let devToolsDriver: CEFDevToolsEngineDriver
    private let composer = BrowserChromiumContextMenuComposer()
    private let presenter = BrowserContextMenuPresenter()
    private var frames: BrowserDevToolsLayoutFrames?

    /// Creates the features of one page.
    /// - Parameters:
    ///   - shim: The shim calls.
    ///   - browserID: The page's browser id, `nil` before Chromium created it or after it closed.
    ///   - pageView: The host view the Chromium page window tracks.
    ///   - layoutStore: Remembers the DevTools dock side and sizes.
    ///   - makeWindow: Makes the undocked DevTools window. Defaults to ``BrowserDevToolsWindow``.
    public init(
        shim: any CEFPageFeatureShim,
        browserID: @escaping @MainActor () -> Int32?,
        pageView: CEFHostView,
        layoutStore: BrowserDevToolsLayoutStore,
        makeWindow: @escaping (NSWindow?) -> any BrowserDevToolsWindowHosting = { BrowserDevToolsWindow(near: $0) }
    ) {
        self.shim = shim
        self.browserID = browserID
        pageHostView = pageView
        nativeFind = BrowserNativeFindSession(driver: CEFNativeFindDriver(shim: shim, browserID: browserID))
        paneView = BrowserDevToolsPaneView(pageView: pageView)
        devTools = BrowserDevToolsPaneController(
            paneView: paneView, store: layoutStore, makeWindow: makeWindow,
            makeHostView: { CEFHostView() }
        )
        devToolsDriver = CEFDevToolsEngineDriver(shim: shim, browserID: browserID)
        devTools.driver = devToolsDriver
        devTools.onLayout = { [weak self] frames in
            self?.frames = frames
            self?.applyOcclusion()
        }
    }

    /// Handles a shim event for this page.
    /// - Parameter event: Any shim event.
    /// - Returns: `true` when the event was this page's DevTools, find or context menu event.
    @discardableResult
    public func handle(_ event: CEFShimEvent) -> Bool {
        guard let id = browserID() else { return false }
        switch event {
        case .findResult(let browser, let count, let activeOrdinal, let isFinal) where browser == id:
            nativeFind.receiveResult(count: count, activeOrdinal: activeOrdinal, isFinal: isFinal)
        case .devToolsWillOpen(let browser) where browser == id:
            devTools.engineWillOpenDevTools()
        case .devToolsOpened(let browser, _, let docked) where browser == id:
            devTools.engineDidOpenDevTools(docked: docked)
        case .devToolsClosed(let browser, _) where browser == id:
            devTools.engineDidCloseDevTools()
        case .tab(.devToolsDockSide, let browser, _, let value) where browser == id:
            devTools.engineDidChooseDockSide(value)
        case .contextMenu(let browser, let token, let x, let y, let itemsJSON, let paramsJSON) where browser == id:
            showContextMenu(token: token, at: CGPoint(x: x, y: y), itemsJSON: itemsJSON, paramsJSON: paramsJSON)
        case .loadStart(let browser, _, _) where browser == id:
            // A new document: the next search starts over.
            nativeFind.resetForNewDocument()
            return false
        case .beforeClose(let browser) where browser == id:
            tearDown()
            return false
        default:
            return false
        }
        return true
    }

    /// Ends find and DevTools; the page is closing.
    public func tearDown() {
        nativeFind.cancelPending()
        devTools.tearDown()
    }

    /// Holes in the page and DevTools windows: the chrome's rects and the divider's grab area.
    private func applyOcclusion() {
        let frames = frames ?? BrowserDevToolsLayoutFrames(page: paneView.bounds, devTools: .zero, line: .zero, grab: .zero)
        var pageRects = chromeOcclusionRects
        if !frames.grab.isEmpty { pageRects.append(frames.grab) }
        pageHostView.occlusionRects = Self.local(pageRects, in: frames.page)
        if let host = devTools.devToolsHostView as? CEFHostView {
            // Docked, the DevTools window sits under the same overlays (a find card at the top
            // right over right-docked DevTools); in its own window nothing covers it.
            host.occlusionRects = host.superview === paneView && !frames.devTools.isEmpty
                ? Self.local(pageRects, in: frames.devTools)
                : []
        }
    }

    /// `rects` (pane coordinates) in a subview at `frame`, clipped to it.
    static func local(_ rects: [CGRect], in frame: CGRect) -> [CGRect] {
        rects.compactMap { rect in
            let clipped = rect.intersection(frame)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            return clipped.offsetBy(dx: -frame.minX, dy: -frame.minY)
        }
    }

    /// The person chose "Open Link in New Tab" in this page's context menu
    /// and Chromium has not opened that tab yet.
    private var contextMenuChoseNewTab = false

    /// Whether the new tab Chromium is opening now comes from the context
    /// menu's "Open Link in New Tab"; reading it clears it.
    public func takeContextMenuNewTab() -> Bool {
        defer { contextMenuChoseNewTab = false }
        return contextMenuChoseNewTab
    }

    private func showContextMenu(token: Int32, at location: CGPoint, itemsJSON: String, paramsJSON: String) {
        contextMenuChoseNewTab = false
        let target = BrowserContextMenuTarget(chromiumParamsJSON: paramsJSON)
        let host = contextMenuHost
        let entries = composer.compose(
            items: BrowserContextMenuItem.decodeChromiumList(itemsJSON),
            target: target,
            defaultBrowserLink: host?.contextMenuDefaultBrowserLink(for: target),
            hostGroups: host?.contextMenuHostGroups(for: target) ?? []
        )
        let shim = self.shim
        presenter.present(
            entries, at: location, in: pageHostView,
            performHostAction: { [weak host] action in host?.performContextMenuHostAction(action) },
            completion: { [weak self] id in
                // The tab Chromium is about to open for this choice opens focused (decision 18).
                self?.contextMenuChoseNewTab = id == BrowserChromiumContextMenuCommand.openLinkInNewTab.rawValue
                shim.contextMenuDone(token: token, commandID: Int32(clamping: id ?? -1))
            }
        )
    }
}
