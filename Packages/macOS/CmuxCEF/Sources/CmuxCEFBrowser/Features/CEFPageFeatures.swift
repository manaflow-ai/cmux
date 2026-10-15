public import AppKit
public import CmuxBrowser
public import CmuxCEF

/// DevTools, find, zoom and the context menu of one Chromium page, wired to the engine-neutral
/// CmuxBrowser models. A CEF page owns one and forwards its shim events here.
///
/// ```swift
/// let features = CEFPageFeatures(shim: CEFShimPageFeatures(library: shim), browserID: id,
///                                pageView: hostView, layoutStore: store)
/// contentView = features.paneView                    // page + docked DevTools + divider
/// runtime.addEventObserver { event in _ = features.handle(event) }
/// ```
@MainActor
public final class CEFPageFeatures {
    /// The page's browser id.
    public let browserID: Int32
    /// Native find for the panel's find bar (``BrowserPageNativeFinding``).
    public let nativeFind: BrowserNativeFindSession
    /// The page's in-pane DevTools (``BrowserPageDevToolsHosting``).
    public let devTools: BrowserDevToolsPaneController
    /// The view the page hands its panel: page plus docked DevTools.
    public let paneView: BrowserDevToolsPaneView
    /// Adds and runs cmux context menu rows; without one, Chromium's own rows show alone.
    public weak var contextMenuHost: (any BrowserContextMenuHosting)?

    private let shim: any CEFPageFeatureShim
    private let devToolsDriver: CEFDevToolsEngineDriver
    private let composer = BrowserChromiumContextMenuComposer()
    private let presenter = BrowserContextMenuPresenter()

    /// Creates the features of one page.
    /// - Parameters:
    ///   - shim: The shim calls.
    ///   - browserID: The page's browser id.
    ///   - pageView: The view the Chromium page window tracks.
    ///   - layoutStore: Remembers the DevTools dock side and sizes.
    ///   - makeWindow: Makes the undocked DevTools window. Defaults to ``BrowserDevToolsWindow``.
    public init(
        shim: any CEFPageFeatureShim,
        browserID: Int32,
        pageView: NSView,
        layoutStore: BrowserDevToolsLayoutStore,
        makeWindow: @escaping (NSWindow?) -> any BrowserDevToolsWindowHosting = { BrowserDevToolsWindow(near: $0) }
    ) {
        self.shim = shim
        self.browserID = browserID
        nativeFind = BrowserNativeFindSession(driver: CEFNativeFindDriver(shim: shim, browserID: browserID))
        paneView = BrowserDevToolsPaneView(pageView: pageView)
        devTools = BrowserDevToolsPaneController(paneView: paneView, store: layoutStore, makeWindow: makeWindow)
        devToolsDriver = CEFDevToolsEngineDriver(shim: shim, browserID: browserID)
        devTools.driver = devToolsDriver
    }

    /// Handles a shim event for this page.
    /// - Parameter event: Any shim event.
    /// - Returns: `true` when the event was this page's DevTools, find or context menu event.
    @discardableResult
    public func handle(_ event: CEFShimEvent) -> Bool {
        switch event {
        case .findResult(let browser, let count, let activeOrdinal, let isFinal) where browser == browserID:
            nativeFind.receiveResult(count: count, activeOrdinal: activeOrdinal, isFinal: isFinal)
        case .devToolsWillOpen(let browser) where browser == browserID:
            devTools.engineWillOpenDevTools()
        case .devToolsOpened(let browser, _, let docked) where browser == browserID:
            devTools.engineDidOpenDevTools(docked: docked)
        case .devToolsClosed(let browser, _) where browser == browserID:
            devTools.engineDidCloseDevTools()
        case .tab(.devToolsDockSide, let browser, _, let value) where browser == browserID:
            devTools.engineDidChooseDockSide(value)
        case .contextMenu(let browser, let token, let x, let y, let itemsJSON, let paramsJSON) where browser == browserID:
            showContextMenu(token: token, at: CGPoint(x: x, y: y), itemsJSON: itemsJSON, paramsJSON: paramsJSON)
        case .loadStart(let browser, _, _) where browser == browserID:
            // A new document: the next search starts over.
            nativeFind.resetForNewDocument()
            return false
        case .beforeClose(let browser) where browser == browserID:
            tearDown()
            return false
        default:
            return false
        }
        return true
    }

    /// Sets the page zoom.
    /// - Parameter factor: The zoom factor; `1` is 100%.
    public func setZoomFactor(_ factor: Double) {
        shim.setZoomLevel(browser: browserID, level: BrowserChromiumZoomLevel(factor: factor).level)
    }

    /// Ends find and DevTools; the page is closing.
    public func tearDown() {
        nativeFind.cancelPending()
        devTools.tearDown()
    }

    private func showContextMenu(token: Int32, at location: CGPoint, itemsJSON: String, paramsJSON: String) {
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
            entries, at: location, in: paneView.pageView,
            performHostAction: { [weak host] action in host?.performContextMenuHostAction(action) },
            completion: { id in shim.contextMenuDone(token: token, commandID: Int32(clamping: id ?? -1)) }
        )
    }
}
