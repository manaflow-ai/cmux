import AppKit
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextLayout

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
/// child window of this window appears, moves, or becomes key, on every
/// event cycle of the window, and whenever the plane syncs.
@MainActor
final class WindowOverlayLayer {
    enum Placement: String { case inWindow, overlayWindow }

    private unowned let window: NSWindow
    /// The window's overlay host: its panel holds the planes (below every
    /// presented overlay) and keeps the order above page windows.
    private var host: WindowOverlayHost { WindowOverlayHost.host(for: window) }
    private var planes: [OverlayPlane] = []
    private(set) var placement: Placement = .inWindow
    /// Interactive overlay rects in window coordinates.
    private(set) var interactiveRects: [CGRect] = []
    /// Divider hit areas in window coordinates.
    private(set) var dividerAreas: [LayoutMouseArea] = []
    let catchers: DividerMouseCatchers
    private var observers: [any NSObjectProtocol] = []
    private var isEvaluating = false
    /// Set by `teardown` (the window is closing): nothing is placed again.
    private var isTornDown = false
    /// A window geometry change whose layout pass has not run yet.
    private var pageUpdateAfterLayout = false
    /// Reorders done (for `debug.layers`).
    var reorderCount: Int { WindowOverlayHost.existingHost(for: window)?.reorderCount ?? 0 }

    init(window: NSWindow) {
        self.window = window
        catchers = DividerMouseCatchers(window: window)
        let center = NotificationCenter.default
        // An occluder (the sidebar) moved: pages re-read their occlusion rects.
        WindowOverlayHost.host(for: window).onOccludersChange = { [weak self] in self?.requestPageUpdate() }
        observers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() } // main-proof: observer on queue: .main
        })
        // Any move or resize source (drag, an Accessibility client such as
        // Rectangle, a display, Space or fullscreen change): the overlay
        // follows, and every Chromium page re-applies its geometry now and
        // once more after the layout pass that the change schedules.
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didChangeBackingPropertiesNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.parentGeometryDidChange() } // main-proof: observer on queue: .main
            })
        }
        // A page window appears (the fork shows it inactive and adds it as a
        // child), moves, or takes key: check the order at once.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let child = note.object as? NSWindow
                let moved = note.name == NSWindow.didMoveNotification || note.name == NSWindow.didResizeNotification
                MainActor.assumeIsolated { // main-proof: observer on queue: .main
                    guard let self, let child, child !== self.window, child.parent === self.window else { return }
                    self.evaluate()
                    if moved {
                        self.pageWindowDidChangeFrame(child)
                    }
                }
            })
        }
    }

    func teardown() {
        isTornDown = true
        catchers.teardown()
        observers.forEach(NotificationCenter.default.removeObserver)
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

    /// The layout root finished a layout pass: pages re-apply once after a
    /// window geometry change, now that their host views have final frames.
    func planeDidLayout(_ plane: OverlayPlane) {
        #if DEBUG
        recordRingLag(plane)
        #endif
        guard pageUpdateAfterLayout else { return }
        pageUpdateAfterLayout = false
        for plane in planes { plane.syncFrame() }
        requestPageUpdate()
    }

    /// Pane corners or padding changed: pages re-read their clip shape.
    func paneShapesDidChange() {
        requestPageUpdate()
    }

    func interactiveRectsDidChange() {
        updateInteractiveRects()
        // The plane syncs on every layout step: a cheap moment to confirm
        // no page window was re-added above the overlay meanwhile.
        evaluate()
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
        if areas != dividerAreas {
            dividerAreas = areas
            syncCatchers()
        }
        guard rects != interactiveRects else { return }
        interactiveRects = rects
        requestPageUpdate()
    }

    // MARK: Placement and order

    /// Visible child windows that draw content above the parent: every child
    /// that is not one of the app's panels (in practice Chromium pages).
    static func contentChildWindows(of window: NSWindow) -> [NSWindow] {
        (window.childWindows ?? []).filter { isContent($0) && $0.isVisible }
    }

    static func isContent(_ child: NSWindow) -> Bool { WindowOverlayHost.isPageWindow(child) }

    /// Moves the planes to where they draw above content, and restores the
    /// child window order when a page window was added above the overlay.
    func evaluate() {
        guard !isEvaluating, !isTornDown else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        let wanted: Placement = window.isVisible && !Self.contentChildWindows(of: window).isEmpty ? .overlayWindow : .inWindow
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

    private func parentGeometryDidChange() {
        if placement == .overlayWindow, let panel = WindowOverlayHost.existingHost(for: window)?.panel,
           panel.parent === window, panel.frame != window.frame {
            panel.setFrame(window.frame, display: false)
        }
        for plane in planes { plane.syncFrame() }
        updateInteractiveRects()
        syncCatchers()
        requestPageUpdate()
        pageUpdateAfterLayout = true
    }

    /// Something other than the fork moved or resized a page window (an
    /// Accessibility client that addressed the page window directly): the
    /// page must stay on its pane, so its host re-places it. A frame the
    /// fork set itself matches a host and changes nothing.
    private func pageWindowDidChangeFrame(_ child: NSWindow) {
        guard Self.isContent(child), child.isVisible, let controller = window.windowController as? WindowController else { return }
        let hosts = ChildPageGeometry.sample(controller).hosts
        guard !hosts.contains(where: { ChildPageGeometry.distance($0.screenRect, child.frame) <= ChildPageGeometry.tolerance }) else { return }
        requestPageUpdate()
    }

    /// Click-catching panels over divider hit areas while pages show.
    private func syncCatchers() {
        if catchers.onHover == nil {
            catchers.onHover = { [weak self] id, hovered in
                for plane in self?.planes ?? [] { (plane.home as? LayoutRootView)?.setDividerHovered(id, hovered) }
            }
        }
        // A modal or dimming overlay blocks the whole window: no divider takes the mouse under it.
        let blocked = WindowOverlayHost.existingHost(for: window)?.blocksWholeWindow == true
        catchers.update(dividerAreas, active: placement == .overlayWindow && !blocked)
        // The panels pass hover through to the layout, and moving them under
        // a still pointer sends no event: the layout recomputes now (cx-ww20).
        for plane in planes {
            guard let root = plane.home as? LayoutRootView else { continue }
            root.hoverPassThroughWindows = { [weak catchers] in catchers?.windowNumbers ?? [] }
            root.refreshDividerHover()
        }
    }

    /// Every Chromium page of this window re-applies geometry, clip and
    /// occlusion (`CEFHostView` posts the fork's geometry notification).
    private func requestPageUpdate() {
        NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window)
    }

    // MARK: Diagnostics

    #if DEBUG
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
        guard let lag = root.overlayRings.first(where: { $0.showsRing && $0.ringInWindow != $0.contentInWindow }) else { return }
        ringLagPasses += 1
        lastRingLag = "\(lag.pane): ring \(lag.ringInWindow), content \(lag.contentInWindow), placement \(placement.rawValue)"
    }
    #endif

    /// Whether the overlay is above every visible content child window (or
    /// not needed because there is none).
    var isOverlayAboveContent: Bool {
        guard !Self.contentChildWindows(of: window).isEmpty else { return true }
        return placement == .overlayWindow && WindowOverlayHost.existingHost(for: window)?.isAbovePages == true
    }

    /// The window's agent cursor layer (`WindowOverlayHost.agentCursorLayer`): y-down, content-view coordinates.
    var agentCursorLayer: CALayer { host.agentCursorLayer }

    var overlayPanel: NSWindow? { WindowOverlayHost.existingHost(for: window).flatMap { $0.isPanelAttached ? $0.panel : nil } }
    var adoptedPlanes: [OverlayPlane] { planes }
}
