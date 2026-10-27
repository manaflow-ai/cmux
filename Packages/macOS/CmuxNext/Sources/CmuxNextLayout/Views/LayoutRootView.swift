public import AppKit
import CmuxNextCompat
public import CmuxNextDesign
import Observation

/// The workspace content area: renders every screen of a `LayoutModel`,
/// hosts App-provided pane views, and turns pointer and trackpad input into
/// `LayoutIntent`s.
///
/// Scrolling follows `layout.scrollModifier` (`LayoutRootView+Scroll`): by
/// default a plain scroll goes to the pane under the pointer and Command +
/// scroll moves the columns strip and rows; the first event of a gesture
/// decides its owner.
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
    /// ``isInLayoutMotion`` at the last report: its end is reported even when no rect changed.
    var reportedLayoutMotion = false
    let driver = DisplayLinkDriver()
    private var observationTask: Task<Void, Never>?
    private var eventMonitor: Any?
    /// Key-window observers of the current window (`observeKeyWindow()`).
    var keyWindowObservers: [any NSObjectProtocol] = []
    private var lastSnapshot: Snapshot?
    /// The last reveal request applied; a newer one waits until its pane is in a screen's layout.
    private var appliedReveal: ColumnCenterRequest?
    private var reportedVisible: Set<PaneID> = []
    private var reportedKeepAlive: Set<PaneID> = []
    var scrollLock: ScrollLock = .idle
    var consumeMomentum = false
    /// The current gesture's touch (`mayBegin`) chose its owner: its `began` keeps it (`LayoutRootView+Scroll`).
    var ownerDecidedAtTouch = false
    /// What focus-follows-mouse reads besides the model (`LayoutRootView+ScrollFocus`).
    let scrollFocusSignals: ScrollFocusSignals
    /// The pane the pointer was last over (`layout.focusFollowsMouse` hover): focus moves
    /// only when the pointer enters another pane, so a keyboard move is not undone by a
    /// small pointer twitch inside the pane it left.
    var hoveredPane: PaneID?
    /// Delivers pointer moves for focus-follows-mouse (owner: self).
    private var hoverTrackingArea: NSTrackingArea?
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
    /// The pane a terminal tab is dragged from: the facing edge of the pane next to it joins
    /// (`DropZoneGeometry.joiningSharedEdge`).
    var tabDragJoinsFrom: PaneID?
    /// The target the drag shows now, and the one the App refused (`hideTabDragHighlight`): a refused
    /// target stays hidden until the target changes, instead of drawing and hiding on every move (#22287).
    var tabDragShownTarget: DropTarget?
    var tabDragRefusedTarget: DropTarget?
    /// The pane edge the drag is over and since when; it splits once held for the dwell.
    var tabDragEdge: (hit: DropTarget, since: CFTimeInterval)?
    /// When the edge under a held pointer arms (a new split); nil when none is pending. The
    /// drag session hit-tests again then, so a still pointer sees the split preview.
    public internal(set) var tabDragDwellDeadline: CFTimeInterval?
    /// A URL dragged in from another app or a web page over a drop zone no pane content took
    /// (`perform` false: may it drop on `target`, for the preview; true: open it there). Nil: the
    /// layout takes no link drops. Links dragged out of a Home chat track the mouse themselves and
    /// use ``updateTabDrag(_:locationInWindow:removing:edgeDwell:)`` instead.
    public var linkDropHandler: ((_ url: URL, _ target: DropTarget, _ perform: Bool) -> Bool)?
    /// Overlay sync observers by id (`observeOverlaySync`).
    var overlaySyncObservers: [Int: () -> Void] = [:]
    var nextOverlaySyncObserver = 0
    /// The overlay is stale (a host or the plane moved); `flushOverlaySync`
    /// syncs it once, before this turn's frame (`setNeedsOverlaySync`).
    var overlayIsStale = false
    var overlayFlushScheduled = false
    /// Pane rings and dims the overlay syncs placed, cumulative (PaneMotionWorkTests: per frame it
    /// is the panes that moved, not every pane).
    var overlayHostsPlaced = 0
    /// Overlay syncs run, cumulative (PaneLayoutBeforeWindowTests: a parked root runs none).
    var overlaySyncs = 0
    /// The panes whose ring, dim or window frame the last overlay sync changed: a pane that moved,
    /// resized, faded or was newly covered. Observers of ``observeOverlaySync(_:)`` read it to touch
    /// only those panes (a Chromium page's geometry post, a divider catcher); empty for a sync that
    /// moved nothing.
    public internal(set) var panesMovedInLastOverlaySync: Set<PaneID> = []
    /// Whether a layout motion runs now (``observeLayoutMotion(_:)``).
    public private(set) var isLayoutInMotion = false
    /// Layout motion observers by id (`observeLayoutMotion`).
    var layoutMotionObservers: [Int: (Bool) -> Void] = [:]

    /// A split or a pane close is springing on some screen: the panes it resizes change size every
    /// frame, and their terminals keep their grids (the PTY resizes once, at rest) until it lands
    /// (plans/cmux-next/close-animation/DESIGN.md, split-spring-animation/DESIGN.md). Called with
    /// true when the first one starts and false when the last one lands; the App holds
    /// `ResizeCoordinator` with it.
    public var onTerminalGridHold: ((Bool) -> Void)?
    /// Called once for each scroll event the layout consumed (a strip, row, area or canvas scroll, or momentum
    /// its spring owns), in that event's dispatch: the App's input dispatch context times it as the layout's
    /// (`key.scroll_frame target=layout`). Never called for an event that goes on to a pane.
    public var onScrollTaken: (() -> Void)?
    /// Called after every motion frame has placed the panes (a pan, a coast or a spring step), so a
    /// view drawn over them from a snapshot of their places (the modifier-hold shortcut chips) can
    /// follow. Runs on the frame's turn: keep it to a flag or a coalesced refresh.
    public var onFramePlaced: (() -> Void)?
    /// Whether a split or a pane close holds the terminals' grids now (``onTerminalGridHold``).
    public var holdsTerminalGrids: Bool { !context.gridHoldScreens.isEmpty }

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
        var canvases: [ScreenID: CanvasScreen]
    }

    /// `contentProvider` is held weakly; the App keeps it alive.
    /// `scrollbarClock` runs the strip scrollbar's `auto` fade-out deadline;
    /// tests inject a manual clock.
    /// `scrollFocusSignals` feeds focus-follows-mouse (`layout.focusFollowsMouse`);
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
        context.userMotionStepped = { [weak self] in self?.setLayoutInMotion(true) }
        context.userMotionEnded = { [weak self] in
            guard let self, !self.screenViews.values.contains(where: \.hasMotion), !self.driver.isRunning else { return }
            self.setLayoutInMotion(false)
        }
        context.gridHoldDidChange = { [weak self] held in self?.onTerminalGridHold?(held) }
        context.stripClipsDidChange = { [weak self] in
            guard let self else { return }
            planeHost?.paneShapesDidChange(overlayPlane)
        }
        highlight.needsFrame = { [weak self] in self?.driver.start() }
        overlayPlane.addSubview(highlight)
        addSubview(overlayPlane)
        registerForDraggedTypes([LayoutTabDrag.pasteboardType, .URL])
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

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override public func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard event.window === window else { return }
        focusPaneForPointerHover(at: event.locationInWindow)
    }

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
        return convert(rect, from: view)
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
            rowOps: model.acceptsRowOps,
            canvases: model.canvases
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
                    rowOps: model.acceptsRowOps,
                    canvases: model.canvases
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

        // Screens. A screen that goes leaves after the new ones took their panes (below): a pane
        // that moves to a new screen (the screen that replaces it) moves inside the window, never
        // out of it and back. A Chromium page's view that leaves its window orders its page window
        // out, and AppKit asks the window server synchronously (`-[NSWindow _doOrderWindow:]`,
        // ~100 ms on a busy host).
        let ids = Set(snapshot.screens.map(\.id))
        let leaving = screenViews.filter { !ids.contains($0.key) }
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
            // A zoomed pane shows full size over its canvas (canvas-layout.md).
            let canvas = screen.zoomed ? nil : snapshot.canvases[screen.id]
            let layoutChanged = isNew || old?.layout != screen.layout || old?.zoomed != screen.zoomed || sharedChanged
                || view.holdsRowDragPreview || canvas != (old?.zoomed == true ? nil : previous?.canvases[screen.id])
            if layoutChanged {
                let structureChanged = old.map { !$0.layout.hasSameStructure(as: screen.layout) } ?? true
                // An explicit equalize (same structure, new ratios) springs whenever motion is allowed (Lawrence
                // 2026-10-16); the sizing after a split or close, and released drags, follow `ui.paneAnimations`.
                let reflows = chromeAnimated && !structureChanged && !snapshot.gestureActive && model.animatesReflow
                // A hidden screen lands at once: frames step only the screens shown (`advanceFrame`), so a
                // spring started there (a restore, a daemon echo) froze its panes mid-motion, their
                // content held wider than the pane and pinned to its edge (Leo 2026-10-21).
                if view.update(layout: screen.layout, zoomed: screen.zoomed, canvas: canvas,
                               animated: (animated || reflows) && !view.isHidden) {
                    needsFrames = true
                }
                // The focus ring of a split's new pane appears with the pane; the focus flash still
                // runs, so the pane after a close or a link's new pane shows where focus went.
                view.updateChrome(focused: snapshot.focused, dimsInactive: snapshot.dimsInactive, attention: snapshot.attention,
                                  animated: chromeAnimated && !structureChanged, flashAnimated: chromeAnimated)
            } else if chromeChanged {
                // A focus move alone changes the chrome of two panes, the one left and the one focused: every
                // other pane keeps its ring, dim and tab emphasis (O(2), not O(panes); speed-of-sound 3.2).
                let focusMoveOnly = previous.map {
                    !sharedChanged && $0.dimsInactive == snapshot.dimsInactive && $0.attention == snapshot.attention
                } ?? false
                view.updateChrome(focused: snapshot.focused, dimsInactive: snapshot.dimsInactive, attention: snapshot.attention,
                                  animated: chromeAnimated,
                                  only: focusMoveOnly ? Set([previous?.focused, snapshot.focused].compactMap { $0 }) : nil)
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

        // A drag's pages whose panes moved to a surviving screen hear its end when that screen lands;
        // the rest (gone with their screen) hear it now.
        var carried: [PaneResizeGestureListener] = []
        for (id, view) in leaving {
            carried += view.takeResizeGestureListeners()
            view.tearDown()
            view.removeFromSuperview()
            screenViews[id] = nil
            screenFrames[id] = nil
        }

        // Screen switch.
        if previous?.activeScreen != snapshot.activeScreen {
            if switchScreens(from: previous?.activeScreen, to: snapshot.activeScreen, order: snapshot.screens.map(\.id), animated: animated) {
                needsFrames = true
            }
        }

        for listener in carried {
            guard let page = listener.view else { continue }
            if let home = screenViews.values.first(where: { page.isDescendant(of: $0) }) {
                home.adoptResizeGestureListeners([listener])
            } else {
                page.paneResizeGestureDidChange(active: false)
            }
        }
        // A released resize drag: its layout is in the screens now (`ScreenContentView+ResizeGesture`).
        for view in screenViews.values where view.resizeGesture == .releasing {
            view.resizeGestureModelSynced(gestureActive: snapshot.gestureActive)
        }
        updateVisibility()
        overlayIsStale = true
        flushOverlaySync()
        // Pane padding or corners changed: pages drawn as child windows
        // re-read their clip shape (their frames may not have moved).
        if let previous, previous.style != snapshot.style { planeHost?.paneShapesDidChange(overlayPlane) }
        if needsFrames || snapshot.gestureActive { driver.start() }
        // A change that starts springs (a split, a close) is in motion from the frame it lands in.
        if needsFrames && driver.isRunning { setLayoutInMotion(true) }
    }

    // MARK: Frames

    func advanceFrame(_ dt: Double) -> Bool {
        defer { onFramePlaced?() }
        // A released resize drag whose layout the observation has not applied yet: apply it before this
        // frame, so the frame that ends the drag for the pane contents is the release's (`ScreenContentView+ResizeGesture`).
        if !model.isGestureActive, screenViews.values.contains(where: { $0.resizeGesture == .releasing }) {
            syncWithModel()
            // Nothing new to apply: the screens already show the model.
            for view in screenViews.values where view.resizeGesture == .releasing { view.resizeGestureModelSynced(gestureActive: false) }
        }
        // Reduce Motion (or the no-animation switch) turned on mid-flight: the final layout now, no more frames.
        if context.reduceMotion {
            for view in screenViews.values where view.hasMotion || view.resizeGesture == .landing { view.settleMotion() }
            for id in Array(screenFrames.keys) { screenFrames[id]?.snap() }
            applyScreenFrames()
            updateVisibility()
            flushOverlaySync()
            setLayoutInMotion(false)
            return false
        }
        // One motion policy per frame (it reads the animation settings), not one per spring.
        let policy = Motion.panes.policy
        var moving = false, panning = false
        for view in screenViews.values where !view.isHidden {
            // Pan events that waited in the last frame show first, then the springs step.
            if view.displayFrameBegan() { panning = true }
            if view.step(dt, policy: policy) { moving = true }
            if view.stepCanvasCamera(dt, policy: policy) { moving = true }
        }
        let screenSpring = policy.spring(.screen)
        for id in Array(screenFrames.keys) {
            if screenFrames[id]?.advance(dt, parameters: screenSpring) == true { moving = true }
        }
        applyScreenFrames()
        if highlight.step(dt) { moving = true }
        updateVisibility()
        // A pan with the finger down is layout motion (`userMotionActive`): a frame tick during it
        // is not its landing, so what waits for the landing (page windows, catcher panels) waits on.
        let gesturing = screenViews.values.contains(where: \.userMotionActive)
        // The frame that lands still syncs as part of the motion; observers hear it ended after it.
        if moving || gesturing { setLayoutInMotion(true) }
        flushOverlaySync()
        if !moving && !gesturing { setLayoutInMotion(false) }
        // A strip pan keeps the ticks a little after each event (`ScreenContentView.panTickTail`);
        // a gesture with a still pointer needs none after that.
        return moving || panning
    }

    /// Tells the layout motion observers when the first spring starts and when the last one lands.
    func setLayoutInMotion(_ moving: Bool) {
        guard moving != isLayoutInMotion else { return }
        isLayoutInMotion = moving
        for block in layoutMotionObservers.values { block(moving) }
        // The landing frame synced while still in motion: the window hears the rest now (catchers).
        if !moving { reportInteractiveRects() }
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
    /// Panes whose chrome (ring, dim, tab emphasis) a sync re-ran, all windows (`debug.layout_counters`).
    public static var paneChromeUpdates: UInt64 = 0

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
    }

    override public func setFrameOrigin(_ newOrigin: NSPoint) {
        let moved = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        // A move keeps the plane's frame here but moves every pane in the
        // window: the hosts re-read their window frames in the sync.
        if overlayPlane.syncFrame() || moved { setNeedsOverlaySync() }
    }

    /// In a window and not hidden or parked: the only state in which this root takes events, runs
    /// frames, lends its overlay plane to the window and reports visible panes. A parked workspace
    /// stays in its window, hidden or parked (`WindowRootView.show`, ``ParkingContainer``), so that is
    /// what parks it, as leaving did.
    public private(set) var isLive = false

    private var isShown: Bool { window != nil && !isHiddenOrHasHiddenAncestor && !isParkedOrHasParkedAncestor }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== window { setLive(false) }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setLive(isShown)
    }

    override public func viewDidHide() {
        super.viewDidHide()
        setLive(false)
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        setLive(isShown)
    }

    public func parkingDidChange() { setLive(isShown) }

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
        if !live {
            for view in screenViews.values {
                view.settleMotion()
                // No frames run while parked or away: a resize drag's pages lay out now (`ScreenContentView+ResizeGesture`).
                view.finishResizeGesture()
            }
        }
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
            if screenViews.values.contains(where: \.hasMotion) || screenFrames.values.contains(where: { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }) { driver.start() }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.handleMonitored(event) ?? event
            }
        }
        updateVisibility()
        // The layout changes it saw while parked: one overlay sync now.
        if live { flushOverlaySync() }
    }

}

extension LayoutRootView: ParkingObserver {}
