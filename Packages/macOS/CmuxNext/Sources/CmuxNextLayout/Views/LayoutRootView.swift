public import AppKit
import CmuxNextCompat
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
    /// Key-window observers of the current window (`observeKeyWindow()`).
    var keyWindowObservers: [any NSObjectProtocol] = []
    private var lastSnapshot: Snapshot?
    /// The last reveal request applied; a newer one waits until its pane is in a screen's layout.
    private var appliedReveal: ColumnCenterRequest?
    private var reportedVisible: Set<PaneID> = []
    /// The agent chat column last posted (`reportAgentChatColumn`).
    var reportedAgentChatColumn: CGRect?
    private var reportedKeepAlive: Set<PaneID> = []
    var scrollLock: ScrollLock = .idle
    var consumeMomentum = false
    /// What scroll-to-focus reads besides the model (`LayoutRootView+ScrollFocus`).
    let scrollFocusSignals: ScrollFocusSignals
    var dragTab: TabID?
    /// The drop preview's rect for the current tab drag target, in screen
    /// coordinates; nil when nothing is highlighted. The drag session flies
    /// the ghost to it, so the ghost lands where the preview showed (R47).
    public internal(set) var tabDragHighlightOnScreen: CGRect?
    /// The zone hit the drop preview shows now; the next hit test holds it
    /// near its line (`DropZoneGeometry.zone`). Nil while nothing shows.
    var tabDropHit: DropTarget?
    /// The pane the current drag empties, as the last preview decided the
    /// split room with it: the drop decides with the same pane (cx-ohle).
    var tabDragRemoving: PaneID?
    /// The pane edge the drag is over and since when; it splits once held for the dwell.
    var tabDragEdge: (hit: DropTarget, since: CFTimeInterval)?
    /// When the edge under a held pointer arms (a new split); nil when none is pending. The
    /// drag session hit-tests again then, so a still pointer sees the split preview.
    public internal(set) var tabDragDwellDeadline: CFTimeInterval?
    /// Overlay sync observers by id (`observeOverlaySync`).
    var overlaySyncObservers: [Int: () -> Void] = [:]
    var nextOverlaySyncObserver = 0
    /// The overlay is stale (a host or the plane moved); `flushOverlaySync`
    /// syncs it once, before this turn's frame (`setNeedsOverlaySync`).
    var overlayIsStale = false
    var overlayFlushScheduled = false

    /// Everything the view reads from the model, observed as one value.
    private struct Snapshot: Equatable, Sendable {
        var screens: [LayoutScreen]
        var activeScreen: ScreenID?
        var focused: PaneID?
        var dimsInactive: Bool
        var style: LayoutStyle
        var gestureActive: Bool
        var centerRequest: ColumnCenterRequest?
        var revealRequest: ColumnCenterRequest?
        var centerMode: CenterFocusedColumn
        var attention: [PaneID: AttentionMark]
        var scrollbar: StripScrollbarMode
        var rowOps: Bool
    }

    /// `contentProvider` is held weakly; the App keeps it alive.
    /// `scrollbarClock` runs the strip scrollbar's `auto` fade-out deadline;
    /// tests inject a manual clock.
    /// `scrollFocusSignals` feeds scroll-to-focus (`layout.focusPaneOnScroll`);
    /// tests inject fixed values.
    public init(model: LayoutModel, contentProvider: any LayoutPaneContentProvider,
                scrollbarClock: any Clock<Duration> = ContinuousClock(),
                scrollFocusSignals: ScrollFocusSignals = ScrollFocusSignals()) {
        self.model = model
        self.scrollFocusSignals = scrollFocusSignals
        self.context = LayoutViewContext(model: model, provider: contentProvider, scrollbarClock: scrollbarClock)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        context.requestFrames = { [weak self] in self?.driver.start() }
        driver.onFrame = { [weak self] dt in self?.advanceFrame(dt) ?? false }
        context.overlayNeedsSync = { [weak self] in self?.setNeedsOverlaySync() }
        context.stripClipsDidChange = { [weak self] in
            guard let self else { return }
            planeHost?.paneShapesDidChange(overlayPlane)
        }
        highlight.needsFrame = { [weak self] in self?.driver.start() }
        overlayPlane.addSubview(highlight)
        addSubview(overlayPlane)
        registerForDraggedTypes([LayoutTabDrag.pasteboardType])
        sync(snapshot())
        observe()
        #if DEBUG
        ScreenContentView.registerMotionSampler()
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            observationTask?.cancel()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            for token in keyWindowObservers { NotificationCenter.default.removeObserver(token) }
            driver.detach()
        }
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
            revealRequest: model.revealRequest,
            centerMode: model.centerFocusedColumn,
            attention: model.attention,
            scrollbar: model.stripScrollbar,
            rowOps: model.acceptsRowOps
        )
    }

    private func observe() {
        let model = model
        observationTask = Task { [weak self] in
            for await snapshot in ObservationStream({
                Snapshot(
                    screens: model.screens,
                    activeScreen: model.activeScreenID,
                    focused: model.focusedPane,
                    dimsInactive: model.dimsInactivePanes,
                    style: model.style,
                    gestureActive: model.isGestureActive,
                    centerRequest: model.centerRequest,
                    revealRequest: model.revealRequest,
                    centerMode: model.centerFocusedColumn,
                    attention: model.attention,
                    scrollbar: model.stripScrollbar,
                    rowOps: model.acceptsRowOps
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
        // Chrome (focus ring, dim) fades whenever motion is allowed; pane frames, the strip's
        // reveal and the screen slide move only with `ui.paneAnimations` (motion.md rule 9).
        let chromeAnimated = previous != nil && canAnimate && !snapshot.gestureActive
        let animated = chromeAnimated && context.animatesPaneLayout
        var needsFrames = false

        if previous?.screens != snapshot.screens { context.livePanes = Set(snapshot.screens.flatMap(\.layout.panes)) }
        // Only a screen whose inputs changed reconciles (I7): a divider drag
        // frame rewrites one screen, and the others (shown or hidden) keep
        // their frames, chrome and scroll.
        let before = Dictionary((previous?.screens ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sharedChanged = previous.map {
            $0.style != snapshot.style || $0.scrollbar != snapshot.scrollbar || $0.rowOps != snapshot.rowOps
        } ?? true
        let chromeChanged = sharedChanged || previous.map {
            $0.focused != snapshot.focused || $0.dimsInactive != snapshot.dimsInactive || $0.attention != snapshot.attention
        } ?? true
        let scrollChanged = previous.map {
            $0.focused != snapshot.focused || $0.centerMode != snapshot.centerMode || $0.gestureActive != snapshot.gestureActive
                || $0.activeScreen != snapshot.activeScreen
        } ?? true

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
            var isNew = false
            if let existing = screenViews[screen.id] {
                view = existing
            } else {
                isNew = true
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
            let old = before[screen.id]
            let layoutChanged = isNew || old?.layout != screen.layout || old?.zoomed != screen.zoomed || sharedChanged
                || view.holdsRowDragPreview
            if layoutChanged {
                let structureChanged = old.map { !$0.layout.hasSameStructure(as: screen.layout) } ?? true
                // An explicit equalize (same structure, new ratios) springs whenever motion is allowed (Lawrence
                // 2026-10-16); the sizing after a split or close, and released drags, follow `ui.paneAnimations`.
                let reflows = chromeAnimated && !structureChanged && !snapshot.gestureActive && model.animatesReflow
                if view.update(layout: screen.layout, zoomed: screen.zoomed, animated: animated || reflows) { needsFrames = true }
                // The focus ring of a split's new pane appears with the pane.
                view.updateChrome(focused: snapshot.focused, dimsInactive: snapshot.dimsInactive, attention: snapshot.attention,
                                  animated: chromeAnimated && !structureChanged)
            } else if chromeChanged {
                view.updateChrome(focused: snapshot.focused, dimsInactive: snapshot.dimsInactive, attention: snapshot.attention,
                                  animated: chromeAnimated)
            }
            // A changed layout or focus reaches the scroll reducer: it anchors
            // the camera on layout changes, reveals focus, and springs back
            // after a close.
            if layoutChanged || scrollChanged {
                let focused = snapshot.focused.flatMap { screen.layout.contains($0) ? $0 : nil }
                let source: ColumnFocusSource = previous?.focused != snapshot.focused ? model.lastFocusSource : .programmatic
                // Only a snap that stands in for Reduce Motion's spring shows the
                // scrollbar, not one at launch or while out of the window.
                if view.syncScroll(focused: focused, source: source, mode: snapshot.centerMode,
                                   animated: previous != nil && canAnimate && context.animatesPaneLayout, reveals: !snapshot.gestureActive,
                                   showsScrollbarOnSnap: previous != nil && window != nil && driver.isAttached) {
                    needsFrames = true
                }
            }
            if let request = snapshot.centerRequest, request != previous?.centerRequest, screen.layout.contains(request.pane),
               view.center(request.pane, animated: animated) {
                needsFrames = true
            }
            if let request = snapshot.revealRequest, request != appliedReveal, screen.layout.contains(request.pane) {
                appliedReveal = request
                if view.center(request.pane, animated: animated, reveal: true) { needsFrames = true }
            }
        }

        // Screen switch.
        if previous?.activeScreen != snapshot.activeScreen {
            if switchScreens(from: previous?.activeScreen, to: snapshot.activeScreen, order: snapshot.screens.map(\.id), animated: animated) {
                needsFrames = true
            }
        }

        updateVisibility()
        overlayIsStale = true
        flushOverlaySync()
        // Pane padding or corners changed: pages drawn as child windows
        // re-read their clip shape (their frames may not have moved).
        if let previous, previous.style != snapshot.style { planeHost?.paneShapesDidChange(overlayPlane) }
        reportAgentChatColumn()
        if needsFrames || snapshot.gestureActive { driver.start() }
    }

    // MARK: Frames

    func advanceFrame(_ dt: Double) -> Bool {
        model.flushPendingGestureIntents()
        // One motion policy per frame (it reads the animation settings), not one per spring.
        let policy = Motion.policy
        var moving = false
        for view in screenViews.values where !view.isHidden {
            if view.step(dt, policy: policy) { moving = true }
        }
        let screenSpring = policy.spring(.screen)
        for id in Array(screenFrames.keys) {
            if screenFrames[id]?.advance(dt, parameters: screenSpring) == true { moving = true }
        }
        applyScreenFrames()
        if highlight.step(dt) { moving = true }
        updateVisibility()
        flushOverlaySync()
        // A gesture requests frames on each pointer change (pending intents);
        // an active gesture with a still pointer needs none.
        return moving || model.hasPendingGestureIntents
    }

    func updateVisibility() {
        var visible: Set<PaneID> = []
        var keepAlive: Set<PaneID> = []
        if isLive, let active = model.activeScreenID, let view = screenViews[active] {
            visible = view.visiblePanes()
            keepAlive = view.keepAlivePanes().union(visible)
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

    /// Layout passes of every root (`debug.layout_counters`): a window resize lays out the shown
    /// workspace only; a parked one keeps its frame until it shows again.
    public static var layoutPasses: UInt64 = 0

    override public func layout() {
        super.layout()
        Self.layoutPasses &+= 1
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
        if overlayPlane.syncFrame() { overlayIsStale = true }
        flushOverlaySync()
        planeHost?.planeDidLayout(overlayPlane)
        reportAgentChatColumn()
    }

    override public func setFrameOrigin(_ newOrigin: NSPoint) {
        let moved = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        // A move keeps the plane's frame here but moves every pane in the
        // window: the hosts re-read their window frames in the sync.
        if overlayPlane.syncFrame() || moved { setNeedsOverlaySync() }
    }

    /// In a window and not hidden: the only state in which this root takes events, runs frames,
    /// lends its overlay plane to the window and reports visible panes. A parked workspace stays in
    /// its window, hidden (`WindowRootView.show`), so hiding is what parks it, as leaving did.
    public private(set) var isLive = false

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== window { setLive(false) }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setLive(window != nil && !isHiddenOrHasHiddenAncestor)
    }

    override public func viewDidHide() {
        super.viewDidHide()
        setLive(false)
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        setLive(window != nil && !isHiddenOrHasHiddenAncestor)
    }

    /// One transition per park or show: O(1) registrations, then one visibility report (the panes
    /// that hide or show), never per frame or per event.
    private func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        driver.detach()
        if !live, let planeHost {
            planeHost.releasePlane(overlayPlane)
            self.planeHost = nil
            returnPlaneHome()
        }
        observeKeyWindow()
        if live {
            if let host = window as? any OverlayPlaneHosting, planeHost !== host {
                planeHost = host
                host.adoptPlane(overlayPlane)
            }
            driver.attach(to: self)
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.handleMonitored(event) ?? event
            }
        }
        updateVisibility()
        reportAgentChatColumn()
    }

}
