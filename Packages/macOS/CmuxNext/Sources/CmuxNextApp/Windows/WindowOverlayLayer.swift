import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSignposts
import CmuxNextWakeups

/// Keeps a window's app overlays above its content child windows.
///
/// Chromium pages are child `NSWindow`s that the CEF fork orders above the
/// whole parent content, so anything drawn in the parent window (focus
/// ring, inactive dim, drop highlight) disappears behind them. Two rules fix
/// this for every overlay:
///
/// - Visual overlays live in the layout's `OverlayPlane`. While the window
///   has a visible content child window, the plane moves into one
///   click-through overlay panel that is a child window ordered directly
///   above every content child window; otherwise it stays in the root view
///   (no extra window, no extra memory). Items are positioned in the root's
///   coordinates either way, so static rings and animated drop zones take
///   the same path.
/// - Overlays that draw and take the mouse (the screen switcher) stay in
///   the parent and are reported to pages as occlusion rects
///   (`BrowserWindowOcclusionProviding`): the fork masks the page there and
///   routes the mouse to the parent.
/// - Divider hit areas draw nothing over panes, so they do not mask pages:
///   `DividerMouseCatchers` covers them with click-catching panels above
///   the pages that forward the mouse to the parent.
///
/// App panels that are child windows (palette, hover cards, group editor)
/// stay above the overlay panel. Child window z-order is the order of
/// `childWindows` (bottom to top) and `order(_:relativeTo:)` has no effect on
/// child windows, so reordering re-adds windows. The fork re-adds a page
/// window whenever it becomes visible, so the order is checked whenever a
/// child window is added, a page window appears, hides, moves or takes key,
/// the window moves or shows again, and whenever the plane syncs; never per
/// event cycle (Chrome: `remote_cocoa/app_shim/views_nswindow_delegate.mm`).
@MainActor
final class WindowOverlayLayer {
    enum Placement: String { case inWindow, overlayWindow }

    unowned let window: NSWindow
    /// The window's overlay host: its panel holds the planes (below every
    /// presented overlay) and keeps the order above page windows.
    var host: WindowOverlayHost { WindowOverlayHost.host(for: window) }
    private(set) var planes: [OverlayPlane] = []
    private(set) var placement: Placement = .inWindow
    /// Interactive overlay rects in window coordinates.
    private(set) var interactiveRects: [CGRect] = []
    /// The layout's divider hit areas in window coordinates (`debug.layers`
    /// `divider_areas_in_window`: pane dividers only, which the perf gate and
    /// live drag scripts grab).
    private(set) var dividerAreas: [LayoutMouseArea] = []
    /// The sidebar's resize band (`setSidebarResizeBand`).
    private(set) var sidebarResizeArea: LayoutMouseArea?
    /// What the catcher panels cover: the divider areas, the sidebar's resize band last.
    private(set) var catcherAreas: [LayoutMouseArea] = []
    static let sidebarResizeAreaID = "sidebar.resize"
    let catchers: DividerMouseCatchers
    /// Takes a `cef.geometry` slice per parent geometry change and catcher sync (tests pass their own).
    private let signposter: Signposter
    /// A `cef.geometry` slice is open: work inside it takes no slice of its own (``inGeometrySlice(_:_:)``).
    private var geometrySliceOpen = false
    /// The window's own notices (its `WindowEvents`), and every window's (a page window's).
    private var subscriptions: [EventSubscription] = []
    private var observers: [MainActorObservation] = []
    /// The visible page windows at the last check: one that orders out may leave `childWindows` first.
    private var shownPages: Set<ObjectIdentifier> = []
    /// The main run loop's turn number (`MainTurnMeter.turnNumber`): the layout depth and the geometry
    /// change's follow-up page update count only in the turn that set them.
    private let currentTurn: @MainActor () -> UInt64
    private var isEvaluating = false
    /// Set by `teardown` (the window is closing): nothing is placed again.
    private var isTornDown = false
    /// A page update asked for during the layout pass: it runs after the pass.
    private var pageUpdateAfterLayout = false
    /// The turn of a window geometry change: the layout pass the change schedules, in that turn, updates
    /// the pages once more. A move or an occlusion change schedules none, and a later turn's pass owes nothing.
    private var geometryTurn: UInt64?
    /// The deferred page update must reach every page (`requestPageUpdate(force:)`).
    private var forcedPageUpdateAfterLayout = false
    /// Depth of the window's layout pass (`ShellWindow.layoutIfNeeded`), in the turn that began it.
    private var openDepth = 0
    private var passTurn: UInt64 = 0
    /// Interactive rects changed during the layout pass: applied after it.
    private var rectsChangedInLayout = false
    /// Placement and child order checks asked for during the layout pass.
    private var evaluateAfterLayout = false
    /// A parent move or resize reported during the layout pass.
    private var geometryAfterLayout = false
    /// Placement and order checks run (`evaluate()` past its guards; tests).
    private(set) var evaluations = 0

    /// `center`: where windows post (tests pass their own); `currentTurn`: the main run loop's turn number.
    init(window: NSWindow, signposter: Signposter = Signposter.cef, center: NotificationCenter = .default,
         currentTurn: @escaping @MainActor () -> UInt64) {
        self.window = window
        self.signposter = signposter
        self.currentTurn = currentTurn
        catchers = DividerMouseCatchers(window: window)
        let events = WindowEvents.of(window, center: center)
        // An occluder (the sidebar) moved: pages re-read their occlusion rects.
        // The sidebar reports from WindowRootView.layout(): inside the
        // window's layout pass the pages follow after it.
        WindowOverlayHost.host(for: window).onOccludersChange = { [weak self] in
            guard let self else { return }
            self.requestPageUpdate()
        }
        // Any move or resize source (drag, an Accessibility client such as
        // Rectangle, a display, Space or fullscreen change): the overlay
        // follows, and every Chromium page re-applies its geometry now and
        // once more after the layout pass that the change schedules. The
        // window may also show again: whether its pages show is checked.
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didChangeBackingPropertiesNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            subscriptions.append(events.subscribe(name, owner: "WindowOverlayLayer") { [weak self] in
                self?.parentGeometryDidChange()
                self?.evaluate()
            })
        }
        // A page window appears (the fork shows it inactive and adds it as a
        // child), hides, moves, or takes key: check the order at once.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification] {
            let moved = name == NSWindow.didMoveNotification || name == NSWindow.didResizeNotification
            observers.append(MainActorObservation(name, center: center, read: { $0.object as? NSWindow }) { [weak self] child in
                guard let self, let child, child !== self.window else { return }
                guard child.parent === self.window || self.shownPages.contains(ObjectIdentifier(child)) else { return }
                self.evaluate()
                if moved {
                    self.pageWindowDidChangeFrame(child)
                }
            })
        }
    }

    func teardown() {
        isTornDown = true
        sidebarResizeArea = nil
        catchers.teardown()
        subscriptions.forEach { $0.cancel() }
        observers.removeAll()
        for plane in planes { (plane.home as? LayoutRootView)?.returnPlaneHome() }
        planes.removeAll()
        WindowOverlayHost.existingHost(for: window)?.setPlanesWantPanel(false)
    }

    // MARK: Planes

    func adopt(_ plane: OverlayPlane) {
        guard !planes.contains(where: { $0 === plane }) else { return }
        planes.append(plane)
        place(plane)
        updateInteractiveRects()
        evaluate()
    }

    func release(_ plane: OverlayPlane) {
        planes.removeAll { $0 === plane }
        updateInteractiveRects()
        evaluate()
    }

    /// The layout root finished its `layout()`. Nothing crosses windows
    /// here: the window's layout pass is still running. `windowDidLayout`
    /// applies the deferred page update once the pass ends.
    func planeDidLayout(_ plane: OverlayPlane) {
        guard layoutDepth == 0 else { return }
        // A layout outside the window's pass (`layoutSubtreeIfNeeded`).
        windowDidLayoutWork()
    }

    /// Depth of the window's layout pass (`ShellWindow.layoutIfNeeded`). A pass never spans turns, so a
    /// depth from an earlier turn was left by an exception AppKit caught mid-pass: it counts as 0, and the
    /// next pass is the outermost one, with its after-pass work.
    var layoutDepth: Int { passTurn == currentTurn() ? openDepth : 0 }

    func windowWillLayout() {
        let turn = currentTurn()
        if passTurn != turn { (openDepth, passTurn) = (0, turn) }
        openDepth += 1
    }

    /// The window's layout pass ended: every view has its final frame.
    /// Panel planes re-read their home's place (an ancestor may have moved
    /// the root without a layout of the root), then pages and catchers
    /// follow once.
    func windowDidLayout() {
        openDepth = max(0, layoutDepth - 1)
        guard openDepth == 0, !isTornDown else { return }
        windowDidLayoutWork()
    }

    private func windowDidLayoutWork() {
        if geometryAfterLayout {
            geometryAfterLayout = false
            parentGeometryDidChange()
        }
        if evaluateAfterLayout {
            evaluateAfterLayout = false
            evaluate()
        }
        resyncPanelPlanes()
        if rectsChangedInLayout {
            rectsChangedInLayout = false
            updateInteractiveRects()
            evaluate()
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        for plane in planes { recordRingLag(plane) }
        #endif
        let followsGeometry = geometryTurn.map { $0 == currentTurn() } ?? false
        geometryTurn = nil
        guard pageUpdateAfterLayout || followsGeometry else { return }
        let force = forcedPageUpdateAfterLayout
        (pageUpdateAfterLayout, forcedPageUpdateAfterLayout) = (false, false)
        for plane in planes { plane.syncFrame() }
        requestPageUpdate(force: force)
    }

    /// Planes in the overlay panel take their frame from the home's rect in
    /// window coordinates, and their rings from the hosts' current frames.
    /// A no-op when nothing moved (frames are compared before they are set).
    private func resyncPanelPlanes() {
        guard placement == .overlayWindow, !isTornDown else { return }
        for plane in planes where !plane.isHome {
            (plane.home as? LayoutRootView)?.resyncOverlay()
        }
    }

    /// Pane corners or padding changed: pages re-read their clip shape.
    func paneShapesDidChange() {
        requestPageUpdate()
    }

    func interactiveRectsDidChange() {
        // Inside the window's layout pass: pages and catcher panels follow
        // after it (`windowDidLayout`), not from inside a view's layout.
        guard layoutDepth == 0 else {
            rectsChangedInLayout = true
            return
        }
        updateInteractiveRects()
        // The plane syncs on every layout step: a cheap moment to confirm
        // no page window was re-added above the overlay meanwhile.
        evaluate()
    }

    /// The sidebar's resize band in window coordinates (nil: hidden). It
    /// reaches over the pane beside the sidebar, so over a page it gets a
    /// catcher panel like a divider's hit area; a page with focus holds key
    /// and would take the mouse there (Leo 2026-10-20).
    func setSidebarResizeBand(_ rect: CGRect?) {
        let area = rect.map { LayoutMouseArea(id: Self.sidebarResizeAreaID, rect: $0, resizesColumns: true) }
        guard !isTornDown, area != sidebarResizeArea else { return }
        sidebarResizeArea = area
        interactiveRectsDidChange()
    }

    private func place(_ plane: OverlayPlane) {
        switch placement {
        case .inWindow:
            (plane.home as? LayoutRootView)?.returnPlaneHome()
        case .overlayWindow:
            guard !isTornDown else { return }
            let container = host.panel.planeContainer
            if plane.superview !== container { container.addSubview(plane) }
            plane.syncFrame()
        }
    }

    private func updateInteractiveRects() {
        var rects: [CGRect] = []
        var areas: [LayoutMouseArea] = []
        for plane in planes {
            guard let root = plane.home as? LayoutRootView, root.window === window else { continue }
            rects += root.interactiveOverlayRects.map { root.convert($0, to: nil) }
            areas += root.dividerMouseAreas.map { area in
                var area = area
                area.rect = root.convert(area.rect, to: nil)
                return area
            }
        }
        dividerAreas = areas
        if let sidebarResizeArea { areas.append(sidebarResizeArea) }
        // A spring moves the dividers on every display frame until it lands: the catcher panels
        // (one window move each, a new panel for a new divider) follow once, at the landing,
        // which the root reports even when no rect changes then (`isInLayoutMotion`).
        let springing = planes.contains { ($0.home as? LayoutRootView)?.isInLayoutMotion == true }
        if areas != catcherAreas, !springing {
            catcherAreas = areas
            syncCatchers()
        }
        guard rects != interactiveRects else { return }
        interactiveRects = rects
        requestPageUpdate()
    }

    // MARK: Placement and order

    /// Moves the planes to where they draw above content, and restores the
    /// child window order when a page window was added above the overlay.
    func evaluate() {
        guard !isEvaluating, !isTornDown else { return }
        // Moving the planes or re-adding child windows from inside a view's
        // layout re-marks the window: after the pass (same display cycle,
        // before the commit, so no frame shows a page over the ring).
        guard layoutDepth == 0 else {
            evaluateAfterLayout = true
            return
        }
        isEvaluating = true
        defer { isEvaluating = false }
        evaluations += 1
        let pages = window.isVisible ? Self.contentChildWindows(of: window) : []
        shownPages = Set(pages.map(ObjectIdentifier.init))
        let wanted: Placement = pages.isEmpty ? .inWindow : .overlayWindow
        if wanted != placement {
            placement = wanted
            switch wanted {
            case .overlayWindow: showPanel()
            case .inWindow: hidePanel()
            }
            planes.forEach(place)
            syncCatchers()
        }
        if placement == .overlayWindow { enforceOrder() }
    }

    private func showPanel() {
        guard !isTornDown else { return }
        host.onBlockingChange = { [weak self] in self?.syncCatchers() }
        host.setPlanesWantPanel(true)
    }

    private func hidePanel() {
        WindowOverlayHost.existingHost(for: window)?.setPlanesWantPanel(false)
    }

    /// Wanted child order, bottom to top: content windows, the host panel,
    /// app panels at its level (`WindowOverlayHost.reassertOrder`).
    private func enforceOrder() {
        WindowOverlayHost.existingHost(for: window)?.reassertOrder()
    }

    private func parentGeometryDidChange() { // perf-hot: 1ms cef-geometry (every window move or resize; posts to every changed page)
        guard layoutDepth == 0 else {
            geometryAfterLayout = true
            return
        }
        inGeometrySlice(.parentGeometry) {
            if placement == .overlayWindow, let panel = WindowOverlayHost.existingHost(for: window)?.panel,
               panel.parent === window, panel.frame != window.frame {
                panel.setFrame(window.frame, display: false)
            }
            for plane in planes { plane.syncFrame() }
            updateInteractiveRects()
            syncCatchers()
            requestPageUpdate()
            geometryTurn = currentTurn()
        }
    }

    /// Runs `body` in one `cef.geometry` slice, or in the slice already open (slices never nest). The end holds the
    /// catcher panels shown and the panels made or re-framed since the begin.
    private func inGeometrySlice(_ source: Signposter.CEFGeometrySource, _ body: () -> Void) {
        guard !geometrySliceOpen else { return body() }
        let interval = signposter.beginCEFGeometry(source)
        let movesBefore = catchers.panelUpdates
        geometrySliceOpen = true
        defer {
            geometrySliceOpen = false
            signposter.endCEFGeometry(interval, catchers: catchers.shownCount, panelMoves: catchers.panelUpdates - movesBefore)
        }
        body()
    }

    /// Something other than the fork moved or resized a page window (an
    /// Accessibility client that addressed the page window directly): the
    /// page must stay on its pane, so its host re-places it. A frame the
    /// fork set itself matches a host and changes nothing.
    private func pageWindowDidChangeFrame(_ child: NSWindow) {
        guard Self.isContent(child), child.isVisible, let controller = window.windowController as? WindowController else { return }
        let hosts = ChildPageGeometry.sample(controller).hosts
        guard !hosts.contains(where: { ChildPageGeometry.distance($0.screenRect, child.frame) <= ChildPageGeometry.tolerance }) else { return }
        // The hosts did not move, so only a forced update re-places the page.
        requestPageUpdate(force: true)
    }

    /// Click-catching panels over divider hit areas while pages show, in one `cef.geometry` slice.
    private func syncCatchers() { // perf-hot: 1ms cef-geometry (one window move per divider catcher panel)
        inGeometrySlice(.catcherSync) { applyCatchers() }
    }

    private func applyCatchers() {
        if catchers.onHover == nil {
            catchers.onHover = { [weak self] id, hovered in
                if id == Self.sidebarResizeAreaID {
                    (self?.window.contentView as? WindowRootView)?.sidebar.refreshResizeHover()
                    return
                }
                for plane in self?.planes ?? [] { (plane.home as? LayoutRootView)?.setDividerHovered(id, hovered) }
            }
        }
        // A modal or dimming overlay blocks the whole window: no divider takes the mouse under it.
        let blocked = WindowOverlayHost.existingHost(for: window)?.blocksWholeWindow == true
        catchers.update(catcherAreas, active: placement == .overlayWindow && !blocked)
        // The panels pass hover through to the layout, and moving them under
        // a still pointer sends no event: the layout recomputes now (cx-ww20).
        for plane in planes {
            guard let root = plane.home as? LayoutRootView else { continue }
            root.hoverPassThroughWindows = { [weak catchers] in catchers?.windowNumbers ?? [] }
            root.refreshDividerHover()
        }
        (window.contentView as? WindowRootView)?.sidebar.refreshResizeHover { [weak catchers] in catchers?.windowNumbers ?? [] }
    }

    /// Every Chromium page of this window whose geometry, clip or occlusion
    /// changed since the fork last read it re-applies them (`CEFHostView`
    /// posts the fork's geometry notification; the others have nothing new).
    /// `force`: every page re-applies, changed or not (a page window moved by another app).
    private func requestPageUpdate(force: Bool = false) {
        // Pages move their child windows on this: after the layout pass.
        guard layoutDepth == 0 else {
            pageUpdateAfterLayout = true
            forcedPageUpdateAfterLayout = forcedPageUpdateAfterLayout || force
            return
        }
        NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window,
                                        userInfo: force ? [browserPagesForceUpdateKey: true] : nil)
    }

    // MARK: Diagnostics

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Layout passes of the root (window resize, sidebar, divider, column
    /// scroll) that ended with a focus ring off its pane, and the last such
    /// mismatch (`debug.layers`). The ring must move in the pass that places
    /// the panes, even while the plane lives in the overlay panel.
    private(set) var ringLayoutPasses = 0
    private(set) var ringLagPasses = 0
    private(set) var lastRingLag: String?

    private func recordRingLag(_ plane: OverlayPlane) {
        guard let root = plane.home as? LayoutRootView else { return }
        ringLayoutPasses += 1
        guard let lag = root.laggingRing else { return }
        ringLagPasses += 1
        lastRingLag = "\(lag.pane): ring \(lag.ringInWindow), content \(lag.contentInWindow), placement \(placement.rawValue)"
    }
    #endif
}
