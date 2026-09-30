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
    private var panel: WindowOverlayPanel?
    private var planes: [OverlayPlane] = []
    private(set) var placement: Placement = .inWindow
    /// Interactive overlay rects in window coordinates.
    private(set) var interactiveRects: [CGRect] = []
    /// Divider hit areas in window coordinates.
    private(set) var dividerAreas: [LayoutMouseArea] = []
    let catchers: DividerMouseCatchers
    private var observers: [any NSObjectProtocol] = []
    private var isEvaluating = false
    /// A window geometry change whose layout pass has not run yet.
    private var pageUpdateAfterLayout = false
    /// Reorders done (for `debug.layers`).
    private(set) var reorderCount = 0

    init(window: NSWindow) {
        self.window = window
        catchers = DividerMouseCatchers(window: window)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
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
                MainActor.assumeIsolated { self?.parentGeometryDidChange() }
            })
        }
        // A page window appears (the fork shows it inactive and adds it as a
        // child), moves, or takes key: check the order at once.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let child = note.object as? NSWindow
                let moved = note.name == NSWindow.didMoveNotification || note.name == NSWindow.didResizeNotification
                MainActor.assumeIsolated {
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
        catchers.teardown()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for plane in planes { (plane.home as? LayoutRootView)?.returnPlaneHome() }
        planes.removeAll()
        if let panel {
            window.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
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
            guard let container = panel?.contentView else { return }
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

    static func isContent(_ child: NSWindow) -> Bool { !(child is NSPanel) }

    /// Moves the planes to where they draw above content, and restores the
    /// child window order when a page window was added above the overlay.
    func evaluate() {
        guard !isEvaluating else { return }
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
        let panel = panel ?? WindowOverlayPanel()
        self.panel = panel
        ThemeStore.shared.adopt(panel)
        panel.setFrame(window.frame, display: false)
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
    }

    private func hidePanel() {
        guard let panel else { return }
        window.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Wanted child order, bottom to top: content windows, the overlay, app
    /// panels at the overlay's level. Panels at a higher level (menus,
    /// suggestion lists) stay above on their own.
    private func enforceOrder() {
        guard let panel else { return }
        let children = window.childWindows ?? []
        guard let overlayIndex = children.firstIndex(where: { $0 === panel }) else {
            window.addChildWindow(panel, ordered: .above)
            return enforceOrder()
        }
        let visible = children.enumerated().filter { $0.element.isVisible || $0.element === panel }
        let contentAbove = visible.contains { $0.offset > overlayIndex && Self.isContent($0.element) }
        let panelsBelow = visible.contains {
            $0.offset < overlayIndex && !Self.isContent($0.element) && $0.element.level <= panel.level
        }
        guard contentAbove || panelsBelow else { return }
        reorderCount += 1
        let panels = children.filter { $0 !== panel && !Self.isContent($0) && $0.level <= panel.level }
        window.removeChildWindow(panel)
        window.addChildWindow(panel, ordered: .above)
        for child in panels {
            window.removeChildWindow(child)
            window.addChildWindow(child, ordered: .above)
        }
    }

    private func parentGeometryDidChange() {
        if let panel, placement == .overlayWindow, panel.frame != window.frame {
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
        catchers.update(dividerAreas, active: placement == .overlayWindow)
    }

    /// Every Chromium page of this window re-applies geometry, clip and
    /// occlusion (`CEFHostView` posts the fork's geometry notification).
    private func requestPageUpdate() {
        NotificationCenter.default.post(name: BrowserChildWindowPages.needsUpdate, object: window)
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
        let children = window.childWindows ?? []
        let content = children.indices.filter { Self.isContent(children[$0]) && children[$0].isVisible }
        guard let last = content.last else { return true }
        guard let panel, placement == .overlayWindow, let index = children.firstIndex(where: { $0 === panel }) else { return false }
        return index > last
    }

    var overlayPanel: NSWindow? { panel }
    var adoptedPlanes: [OverlayPlane] { planes }
}

/// The click-through overlay child window: transparent, never key, never
/// shown in window lists, no shadow or animation.
final class WindowOverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        let container = NSView()
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        contentView = container
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
