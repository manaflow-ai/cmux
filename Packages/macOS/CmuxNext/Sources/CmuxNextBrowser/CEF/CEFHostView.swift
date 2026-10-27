import AppKit
import CmuxNextDesign
import CmuxNextSignposts

/// The parent view of a pane's Chromium window. The fork's
/// `CmuxParentViewTracker` keeps the page window over this view, clips it to
/// the visible rect, punches holes where native UI must show above the page
/// (find bar, prompt bar) or must get the mouse (the window's dividers and
/// switcher, `BrowserWindowOcclusionProviding`), and masks it to the rounded
/// pane and window corners. What it reads lives in `ChildWindowPageFallback`.
///
/// With the feature `cefAttachedPages` and the fork's attach call, each tab's Chromium view is a subview of
/// this view instead (`CEFLayerHosting.attachedPages`, Chrome's model): the page draws, takes clicks and keys
/// and gets the first responder as any view does, after the window's key routing (`KeyRouter` in
/// `sendEvent` and the window's `performKeyEquivalent` run before any view's), and the page window never
/// orders in. Layer hosting and the page window above are the fallback of a tab the fork does not attach.
final class CEFHostView: NSView {
    /// Rects in this view's coordinates where native UI covers the page.
    var occlusionRects: [CGRect] = [] {
        didSet {
            guard occlusionRects != oldValue else { return }
            postGeometryChange()
            for case let page as ChromiumHostPageView in subviews { showOcclusion(in: page) }
        }
    }

    /// Host mode: `page`'s cursor leaves out the native UI over the page, as the page window does.
    func showOcclusion(in page: ChromiumHostPageView) {
        page.cursorHoles = occlusionRects.map { convert($0, to: page) }
    }
    /// The shown page's own background (`CEFTab.pageBackdropColor`). While
    /// the window live-resizes, this view fills with it instead of the pane
    /// ground: the page window's gap shows this view until Chromium's frame
    /// at the new size arrives (`CEFTab+ResizeBackdrop`).
    var pageBackdrop: CGColor? {
        didSet { if pageBackdrop != oldValue { updateBackground() } }
    }
    /// The shown page is see-through (a cmux page, `CEFTab.pageSeeThrough`): this view under it
    /// paints nothing, so the pane and the window backdrop show as under a WebKit page.
    var pageSeeThrough = false {
        didSet { if pageSeeThrough != oldValue { updateBackground() } }
    }

    /// Called when the window starts a live resize (`CEFPaneHost` re-reads
    /// the shown page's background).
    var liveResizeWillStart: (() -> Void)?
    /// Hands files dragged in from another app to the shown page (`CEFFileDragRelay`).
    let fileDrag = CEFFileDragRelay()
    /// Layer hosting (fork API 26) of the page window over this view, or its tabs' attached Chromium views
    /// (`CEFLayerHosting`).
    let layerHosting: CEFLayerHosting
    /// Widgets that order an attached page's window in over this view (`CEFPageWindowWidgets`).
    let pageWindowWidgets = CEFPageWindowWidgets()
    /// Takes a `cef.geometry` instant per geometry post (tests set one on their own trace runtime).
    var signposter = Signposter.cef
    /// Where its window's page update requests arrive (`BrowserPageUpdates`): `.default` in the app,
    /// a private center in tests.
    let pageUpdateCenter: NotificationCenter

    /// - Parameters:
    ///   - pageUpdateCenter: where its window's page update requests arrive.
    ///   - layerHosting: the page's layer hosting; tests pass one with a fake fork and their own turn.
    init(frame: NSRect, pageUpdateCenter: NotificationCenter, layerHosting: CEFLayerHosting) {
        self.pageUpdateCenter = pageUpdateCenter
        self.layerHosting = layerHosting
        super.init(frame: frame)
        wantsLayer = true
        updateBackground()
        fileDrag.view = self
        layerHosting.view = self
        // The page window ordered in or out for a widget: the fork places it over this view now.
        pageWindowWidgets.changed = { [weak self] in self?.childWindowPage.pagesNeedUpdate(force: true) }
        #if DEBUG || CMUX_BENCH_HOOKS
        Self.registerMotionSampler()
        #endif
    }

    /// A host view that takes its window's page update requests on `NotificationCenter.default`.
    override convenience init(frame: NSRect) {
        self.init(frame: frame, pageUpdateCenter: .default, layerHosting: CEFLayerHosting())
    }

    /// A host view with its own page update center (tests) and the app's layer hosting.
    convenience init(frame: NSRect, pageUpdateCenter: NotificationCenter) {
        self.init(frame: frame, pageUpdateCenter: pageUpdateCenter, layerHosting: CEFLayerHosting())
    }

    /// A host view with its own layer hosting (tests) that takes page update requests on `.default`.
    convenience init(frame: NSRect, layerHosting: CEFLayerHosting) {
        self.init(frame: frame, pageUpdateCenter: .default, layerHosting: layerHosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResizeWillStart?()
        layerHosting.windowLiveResize(active: true)
        updateBackground()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        layerHosting.windowLiveResize(active: false)
        updateBackground()
    }

    /// The content lifecycle shows and hides the shown page by this flag (`CEFTab.setContentVisible`,
    /// `CEFPaneHost.present`): a hosted page's layer goes with it in this transaction, and the fork
    /// hears the page's visibility after the commit (`CEFLayerHosting.visibilityMayHaveChanged`).
    override var isHidden: Bool {
        didSet { if isHidden != oldValue { layerHosting.visibilityMayHaveChanged() } }
    }

    /// Until Chromium's page window shows its first frame, the page area
    /// follows the shared pane ground. It stays clear over Liquid Glass so
    /// the window backdrop remains visible. During a live resize it takes
    /// the page's own background (`pageBackdrop`). Under a see-through page
    /// (`pageSeeThrough`) it paints nothing, so the page shows what a WebKit
    /// page shows.
    private func updateBackground() {
        if pageSeeThrough {
            layer?.backgroundColor = nil
            return
        }
        if inLiveResize, let pageBackdrop {
            layer?.backgroundColor = pageBackdrop
            return
        }
        performWithTheme {
            layer?.backgroundColor = Palette.paneFill.cgColor
        }
    }

    /// What the fork's page tracker reads, and the window's page update requests, while the fork has
    /// a page window over this view (`ChildWindowPageFallback`).
    private(set) lazy var childWindowPage: ChildWindowPageGeometry = {
        let geometry = ChildWindowPageGeometry()
        geometry.view = self
        return geometry
    }()

    /// The pane's rounded clip, the column strip's clip and the window's corners, in this view.
    var pageClip: CGPath? { childWindowPage.clipShape().path }

    /// `rects` without those inside another (one of equal rects stays): a
    /// hole inside a hole, such as the error page's in the New Tab page's,
    /// would cancel it in an even-odd mask and show the page there again.
    static func outermost(_ rects: [CGRect]) -> [CGRect] {
        rects.enumerated().filter { index, rect in
            !rects.enumerated().contains { other, outer in
                other != index && outer.contains(rect) && (outer != rect || other < index)
            }
        }.map(\.element)
    }

    /// The shown tab's attached Chromium view takes this view's bounds (`CEFAttachedPages`), as Chrome sizes
    /// a tab's view to its contents container (`WebContentsViewMac::SetBounds`); the find bar and the other
    /// subviews stay above it. No fork call: Chromium hears the new size from its own view.
    override func layout() { // perf-hot: 0.1ms cef-geometry (each layout of a pane's host view)
        super.layout()
        layerHosting.attachedPages.layout()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layerHosting.attachedPages.layout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A resize-wait tunable edit made while out of a window applies (CEFResizeSyncDeadline).
        layerHosting.windowDidChange()
        childWindowPage.windowDidChange()
    }

    /// Tells the tracker about moves AppKit does not report (layer
    /// transforms, manual frame animation in an ancestor).
    /// Each post is one `cef.geometry` instant.
    func postGeometryChange() { // perf-hot: 0.2ms cef-geometry (each post makes the fork re-place one page window)
        Self.trackerStats.geometryPosts += 1
        signposter.cefGeometryPost()
        NotificationCenter.default.post(name: CEFHostView.geometryDidChange, object: self)
    }

    /// What the fork's tracker read from host views so far (`debug.cef` `tracker`).
    static var trackerStats = CEFTrackerStats()

    /// `CmuxParentViewGeometryDidChange` in the fork.
    static let geometryDidChange = Notification.Name("CmuxParentViewGeometryDidChange")
}

/// A CEF tab's `contentView`. All tabs of a pane share one Chromium window,
/// so the container only borrows the pane's `CEFHostView` while it is in a
/// window, and shows a snapshot while the tab is occluded.
final class CEFTabContentView: NSView, PaneMotionSettling {
    weak var tab: CEFTab?
    private let snapshotView = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.autoresizingMask = [.width, .height]
        snapshotView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Not flipped, like CEFHostView, so occlusion rects in this view's
    // coordinates are also valid in the host view that fills it.

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tab?.pageThemeDidChange()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        tab?.deviceEmulationViewDidResize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let tab else { return }
        tab.pageThemeDidChange()
        // A tab parked hidden in its pane (PaneContentView+Parking) shows
        // when it is unhidden, not when it enters the window.
        if window != nil, !isHiddenOrHasHiddenAncestor {
            tab.contentDidAppear(in: self)
        } else {
            tab.contentDidDisappear()
        }
    }

    /// The pane parked this tab (another tab of the pane shows): it lets the
    /// shared host view go, as when it leaves the window, at no window move.
    override func viewDidHide() {
        super.viewDidHide()
        tab?.contentDidDisappear()
    }

    /// The pane shows this parked tab again: it takes the host view.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        guard let tab, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        tab.pageThemeDidChange()
        tab.contentDidAppear(in: self)
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContent()
    }

    /// The page (the pane's shared `CEFHostView` and the snapshot) takes
    /// the page frame; a docked DevTools and its divider take the rest.
    func layoutContent() {
        let frames = tab?.devToolsController.frames(in: bounds)
            ?? CEFDevToolsLayout.Frames(page: bounds, devTools: .zero, line: .zero, grab: .zero)
        let devToolsHost = tab?.devToolsController.views?.host
        // A fit (cx-qby5j) shows the page in its presented rect inside the frame view.
        let emulation = tab?.deviceEmulation
        // The frame stays under the host view (the pane host is re-added at the bottom on a tab switch).
        if let frame = subviews.first(where: { $0 is BrowserFitFrameView }), subviews.first !== frame {
            addSubview(frame, positioned: .below, relativeTo: nil)
        }
        // With a side panel, Chromium's window holds the panel and the page, so the host keeps the page frame.
        // DevTools device mode places the page itself (the fit yields until it ends).
        // In a DevTools window the page keeps its full frame, but the fit still yields.
        let deviceMode = tab?.devToolsController.deviceModeOn ?? false
        let fitPage = tab?.sidePanel.state == nil && !deviceMode ? emulation?.presentedRect(in: pageViewportFrame) : nil
        for subview in subviews {
            let frame: CGRect
            if let fitFrame = subview as? BrowserFitFrameView {
                frame = pageViewportFrame
                if let fitPage, let viewport = emulation.flatMap({ $0.viewport(in: $0.layoutArea(in: pageViewportFrame).size) }) {
                    let presented = fitPage.offsetBy(dx: -frame.minX, dy: -frame.minY)
                    fitFrame.update(emulation: emulation, presented: presented, layout: viewport.size, scale: viewport.scale)
                }
            } else if subview is SidePanelHeaderView {
                frame = tab?.sidePanel.headerFrame ?? .zero
            } else if subview === devToolsHost {
                frame = frames.devTools
            } else if subview is CEFDevToolsDivider {
                frame = frames.grab
            } else {
                frame = fitPage ?? frames.page
            }
            if subview.frame != frame { subview.frame = frame }
        }
        tab?.applyOcclusion()
        // DevTools or the side panel moved the page area without a resize of this view: refit.
        if let tab, let emulation, !deviceMode, emulation.viewport(in: emulation.layoutArea(in: pageViewportFrame).size) != tab.deviceEmulationViewport {
            tab.applyDeviceEmulation()
        }
    }

    /// The pane's layout spring landed (a split's new pane grown in, a close, a zoom): the shown
    /// page is placed and clipped at the landed frame (`CEFPaneHost.paneMotionSettled`).
    func paneMotionDidSettle() {
        guard let tab, tab.host.hostView.superview === self else { return }
        tab.host.paneMotionSettled(tab)
    }

    /// Adds the fit frame under the page for a fit and removes it otherwise.
    func updateFitFrame() {
        let current = subviews.first { $0 is BrowserFitFrameView }
        if tab?.deviceEmulation?.fit != nil, current == nil {
            addSubview(BrowserFitFrameView(), positioned: .below, relativeTo: subviews.first)
        } else if tab?.deviceEmulation?.fit == nil, let current {
            current.removeFromSuperview()
        }
        needsLayout = true // invalidate: a new emulation (`applyEmulation`'s change check) moves the page to its fit
    }
}
