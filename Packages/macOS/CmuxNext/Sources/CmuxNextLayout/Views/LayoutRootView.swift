public import AppKit
import CmuxNextDesign
import Observation

/// The workspace content area: renders every screen of a `LayoutModel`,
/// hosts App-provided pane views, and turns pointer and trackpad input into
/// `LayoutIntent`s.
///
/// Horizontal trackpad scrolling over a columns screen belongs to the layout
/// even when a hosted view (a terminal) is under the pointer: the first
/// dominant axis of each gesture decides, and vertical gestures pass through.
public final class LayoutRootView: NSView {
    public let model: LayoutModel
    let context: LayoutViewContext
    var screenViews: [ScreenID: ScreenContentView] = [:]
    var screenFrames: [ScreenID: AnimatedFrame] = [:]
    let highlight = DropHighlightView()
    /// Non-interactive overlays (rings, dims, drop highlight). See
    /// `OverlayPlane`: the window may lift it above content child windows.
    public private(set) lazy var overlayPlane = OverlayPlane(home: self)
    weak var planeHost: (any OverlayPlaneHosting)?
    var reportedInteractiveRects: [CGRect] = []
    var reportedDividerMouseAreas: [LayoutMouseArea] = []
    let driver = DisplayLinkDriver()
    private var observationTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private var lastSnapshot: Snapshot?
    private var reportedVisible: Set<PaneID> = []
    private var reportedKeepAlive: Set<PaneID> = []
    var scrollLock: ScrollLock = .idle
    var consumeMomentum = false
    var dragTab: TabID?
    /// The drop preview's rect for the current tab drag target, in screen
    /// coordinates; nil when nothing is highlighted. The drag session flies
    /// the ghost to it, so the ghost lands where the preview showed (R47).
    public internal(set) var tabDragHighlightOnScreen: CGRect?
    /// The zone hit the drop preview shows now; the next hit test holds it
    /// near its line (`DropZoneGeometry.zone`). Nil while nothing shows.
    var tabDropHit: DropTarget?
    /// Overlay sync observers by id (`observeOverlaySync`).
    var overlaySyncObservers: [Int: () -> Void] = [:]
    var nextOverlaySyncObserver = 0

    /// Everything the view reads from the model, observed as one value.
    private struct Snapshot: Equatable, Sendable {
        var screens: [LayoutScreen]
        var activeScreen: ScreenID?
        var focused: PaneID?
        var dimsInactive: Bool
        var style: LayoutStyle
        var gestureActive: Bool
        var centerRequest: ColumnCenterRequest?
        var centerMode: CenterFocusedColumn
        var attention: [PaneID: AttentionMark]
        var scrollbar: StripScrollbarMode
    }

    /// `contentProvider` is held weakly; the App keeps it alive.
    /// `scrollbarClock` runs the strip scrollbar's `auto` fade-out deadline;
    /// tests inject a manual clock.
    public init(model: LayoutModel, contentProvider: any LayoutPaneContentProvider,
                scrollbarClock: any Clock<Duration> = ContinuousClock()) {
        self.model = model
        self.context = LayoutViewContext(model: model, provider: contentProvider, scrollbarClock: scrollbarClock)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        context.requestFrames = { [weak self] in self?.driver.start() }
        driver.onFrame = { [weak self] dt in self?.frame(dt) ?? false }
        context.overlayNeedsSync = { [weak self] in self?.syncOverlay() }
        highlight.needsFrame = { [weak self] in self?.driver.start() }
        overlayPlane.addSubview(highlight)
        addSubview(overlayPlane)
        registerForDraggedTypes([LayoutTabDrag.pasteboardType])
        sync(snapshot())
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        observationTask?.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        driver.detach()
    }

    override public var isFlipped: Bool { true }

    // MARK: Public API

    /// Moves focus to the neighbor in `direction`, scrolling its column into view.
    @discardableResult
    public func moveFocus(_ direction: LayoutDirection) -> PaneID? {
        guard let active = model.activeScreenID, let view = screenViews[active] else { return nil }
        return model.moveFocus(direction, frames: view.navigationFrames)
    }

    /// The hosted content view of `pane`, if it has been created.
    public func contentView(for pane: PaneID) -> NSView? {
        context.hosts[pane]?.content
    }

    /// Where a split of `pane` along `axis` would go given the current
    /// viewport (`SplitRoom`). `removing` is a pane that disappears in the
    /// same step (a moved tab's source pane when it was its only tab).
    /// Returns `.split` for a pane this view does not show or has not measured.
    public func splitPlacement(splitting pane: PaneID, axis: SplitAxis, removing: PaneID? = nil) -> SplitPlacement {
        guard let screen = model.screen(containing: pane), let view = screenViews[screen.id] else { return .split }
        return view.splitPlacement(splitting: pane, axis: axis, removing: removing)
    }

    /// Pane frames of the active screen for directional focus: docked
    /// columns placed before and after the strip (one logical line).
    public var navigationFrames: [PaneID: CGRect] {
        guard let active = model.activeScreenID, let view = screenViews[active] else { return [:] }
        return view.navigationFrames
    }

    /// Displayed frame of `pane` in this view's coordinates (active screen only).
    public func frame(of pane: PaneID) -> CGRect? {
        guard let active = model.activeScreenID, let view = screenViews[active], let rect = view.displayedFrame(of: pane) else { return nil }
        return rect.offsetBy(dx: view.frame.minX, dy: view.frame.minY)
    }

    // MARK: Observation

    private func snapshot() -> Snapshot {
        Snapshot(
            screens: model.screens,
            activeScreen: model.activeScreenID,
            focused: model.focusedPane,
            dimsInactive: model.dimsInactivePanes,
            style: model.style,
            gestureActive: model.isGestureActive,
            centerRequest: model.centerRequest,
            centerMode: model.centerFocusedColumn,
            attention: model.attention,
            scrollbar: model.stripScrollbar
        )
    }

    private func observe() {
        let model = model
        observationTask = Task { [weak self] in
            for await snapshot in Observations({
                Snapshot(
                    screens: model.screens,
                    activeScreen: model.activeScreenID,
                    focused: model.focusedPane,
                    dimsInactive: model.dimsInactivePanes,
                    style: model.style,
                    gestureActive: model.isGestureActive,
                    centerRequest: model.centerRequest,
                    centerMode: model.centerFocusedColumn,
                    attention: model.attention,
                    scrollbar: model.stripScrollbar
                )
            }) {
                guard let self else { return }
                if snapshot != self.lastSnapshot { self.sync(snapshot) }
            }
        }
    }

    /// Mirrors the model now instead of on the observation's next turn.
    /// The App calls it after applying a daemon tree, so the frame that
    /// shows a workspace (or a split, close or new tab in it) already has
    /// its panes and tab strips; the observation then finds nothing new.
    public func syncWithModel() {
        let current = snapshot()
        if current != lastSnapshot { sync(current) }
    }

    var canAnimate: Bool { window != nil && driver.isAttached && !context.reduceMotion }

    private func sync(_ snapshot: Snapshot) {
        let previous = lastSnapshot
        lastSnapshot = snapshot
        let animated = previous != nil && canAnimate && !snapshot.gestureActive
        var needsFrames = false

        context.livePanes = Set(snapshot.screens.flatMap(\.layout.panes))

        // Screens.
        let ids = Set(snapshot.screens.map(\.id))
        for (id, view) in screenViews where !ids.contains(id) {
            view.tearDown()
            view.removeFromSuperview()
            screenViews[id] = nil
            screenFrames[id] = nil
        }
        for screen in snapshot.screens {
            let isActive = screen.id == snapshot.activeScreen
            let view: ScreenContentView
            if let existing = screenViews[screen.id] {
                view = existing
            } else {
                view = ScreenContentView(screenID: screen.id, layout: screen.layout, context: context)
                view.frame = bounds
                view.isHidden = !isActive
                if overlayPlane.isHome {
                    addSubview(view, positioned: .below, relativeTo: overlayPlane)
                } else {
                    addSubview(view)
                }
                screenViews[screen.id] = view
                screenFrames[screen.id] = AnimatedFrame(bounds, alpha: isActive ? 1 : 0)
            }
            let structureChanged = previous?.screens.first(where: { $0.id == screen.id }).map { !$0.layout.hasSameStructure(as: screen.layout) } ?? true
            if view.update(layout: screen.layout, animated: animated) { needsFrames = true }
            // The focus ring of a split's new pane appears with the pane.
            view.updateChrome(focused: snapshot.focused, dimsInactive: snapshot.dimsInactive, attention: snapshot.attention,
                              animated: animated && !structureChanged)
            // Every snapshot reaches the scroll reducer: it anchors the camera
            // on layout changes, reveals focus, and springs back after a close.
            let focused = snapshot.focused.flatMap { screen.layout.contains($0) ? $0 : nil }
            let source: ColumnFocusSource = previous?.focused != snapshot.focused ? model.lastFocusSource : .programmatic
            // Only a snap that stands in for Reduce Motion's spring shows the
            // scrollbar, not one at launch or while out of the window.
            if view.syncScroll(focused: focused, source: source, mode: snapshot.centerMode,
                               animated: previous != nil && canAnimate, reveals: !snapshot.gestureActive,
                               showsScrollbarOnSnap: previous != nil && window != nil && driver.isAttached) {
                needsFrames = true
            }
            if let request = snapshot.centerRequest, request != previous?.centerRequest, screen.layout.contains(request.pane),
               view.center(request.pane, animated: animated) {
                needsFrames = true
            }
        }

        // Screen switch.
        if previous?.activeScreen != snapshot.activeScreen {
            if switchScreens(from: previous?.activeScreen, to: snapshot.activeScreen, order: snapshot.screens.map(\.id), animated: animated) {
                needsFrames = true
            }
        }

        updateVisibility()
        syncOverlay()
        // Pane padding or corners changed: pages drawn as child windows
        // re-read their clip shape (their frames may not have moved).
        if let previous, previous.style != snapshot.style { planeHost?.paneShapesDidChange(overlayPlane) }
        if needsFrames || snapshot.gestureActive { driver.start() }
    }

    // MARK: Frames

    private func frame(_ dt: Double) -> Bool {
        model.flushPendingGestureIntents()
        var moving = false
        for view in screenViews.values where !view.isHidden {
            if view.step(dt) { moving = true }
        }
        for id in Array(screenFrames.keys) {
            if screenFrames[id]?.advance(dt, parameters: Motion.spring(.screen)) == true { moving = true }
        }
        applyScreenFrames()
        if highlight.step(dt) { moving = true }
        updateVisibility()
        syncOverlay()
        // A gesture requests frames on each pointer change (pending intents);
        // an active gesture with a still pointer needs none.
        return moving || model.hasPendingGestureIntents
    }

    /// While detached from its window, report the panes that were visible
    /// or in the keep-alive band as keep-alive instead of hidden (a parked
    /// workspace: its surfaces stay mounted and paused, so showing it again
    /// draws in one frame with no re-attach).
    public var keepsPanesWhenDetached = false

    func updateVisibility() {
        var visible: Set<PaneID> = []
        var keepAlive: Set<PaneID> = []
        if window != nil, let active = model.activeScreenID, let view = screenViews[active] {
            visible = view.visiblePanes()
            keepAlive = view.keepAlivePanes().union(visible)
        } else if keepsPanesWhenDetached {
            // Parked (a recently shown workspace kept warm): what showed or
            // was in the band stays in the band, paused but never released.
            keepAlive = reportedKeepAlive.union(reportedVisible)
        }
        guard visible != reportedVisible || keepAlive != reportedKeepAlive else { return }
        var changes: [(PaneID, PanePresence)] = []
        for pane in reportedKeepAlive.union(keepAlive) {
            let before = PanePresence(pane, visible: reportedVisible, keepAlive: reportedKeepAlive)
            let after = PanePresence(pane, visible: visible, keepAlive: keepAlive)
            if before != after { changes.append((pane, after)) }
        }
        reportedVisible = visible
        reportedKeepAlive = keepAlive
        model.reportVisiblePanes(visible, keepAlive: keepAlive)
        // Losses first, so content leaving the band frees room before new
        // content attaches.
        for (pane, presence) in changes.sorted(by: { $0.1.rank < $1.1.rank }) {
            context.provider?.panePresenceDidChange(pane, presence: presence)
        }
    }

    // MARK: Layout and window

    override public func layout() {
        super.layout()
        for (id, view) in screenViews {
            if view.frame.size != bounds.size { view.setFrameSize(bounds.size) }
            if var frame = screenFrames[id] {
                let target = id == model.activeScreenID ? bounds : bounds.offsetBy(dx: 0, dy: 0)
                frame.setTarget(target)
                frame.x.snap(); frame.y.snap(); frame.width.snap(); frame.height.snap()
                screenFrames[id] = frame
            }
        }
        applyScreenFrames()
        updateVisibility()
        overlayPlane.syncFrame()
        syncOverlay()
        planeHost?.planeDidLayout(overlayPlane)
    }

    override public func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        overlayPlane.syncFrame()
        syncOverlay()
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard let planeHost, newWindow !== window else { return }
        planeHost.releasePlane(overlayPlane)
        self.planeHost = nil
        returnPlaneHome()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let host = window as? any OverlayPlaneHosting, planeHost !== host {
            planeHost = host
            host.adoptPlane(overlayPlane)
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        driver.detach()
        observeKeyWindow()
        guard window != nil else {
            updateVisibility()
            return
        }
        driver.attach(to: self)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.handleMonitored(event) ?? event
        }
        updateVisibility()
    }

}
