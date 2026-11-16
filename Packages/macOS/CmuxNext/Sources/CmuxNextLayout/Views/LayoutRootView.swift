public import AppKit
import CmuxNextCompat
public import CmuxNextWakeups
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
public final class LayoutRootView: NSView, FrameNoticeReadersHosting {
    public let model: LayoutModel
    /// Views in the panes whose frame notices are read, which a resize drag never holds (`FrameNoticeHold`).
    public let frameNoticeReaders = FrameNoticeReaders()
    let context: LayoutViewContext
    /// Every screen's view, each filling the root; the active one shows and the others are hidden
    /// (``showScreen(_:)``: a change of screen has no transition).
    var screenViews: [ScreenID: ScreenContentView] = [:]
    /// With a queue, a hidden screen's view, and the panes it mounts, is made the first time the screen shows or as
    /// background work on this queue once the layout is live and still (`LayoutRootView+DeferredScreens`), not with
    /// the shown one: the frame that shows a workspace pays for the screen it shows only (Leo 2026-11-04: the visible
    /// window comes first, off-screen work is deferred). Without one (nil) every screen is made at once.
    let hiddenScreenQueue: FrameBatchQueue?
    var defersHiddenScreens: Bool { hiddenScreenQueue != nil }
    /// The hidden screens whose views are not made yet, in screen order (``hiddenScreenQueue``).
    public private(set) var deferredScreens: [ScreenID] = []
    /// The waiting screen ``mountDeferredScreen()`` makes in its sync.
    private var mountingScreen: ScreenID?
    /// A deferred mount is waiting to run (`mountDeferredScreensWhenIdle`).
    var deferredMountQueued = false
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
    /// Asks a web page whether it keeps a Command scroll (`layout.pagesHandleCommandScroll`); nil:
    /// every Command scroll is the layout's.
    let pageCommandScroll: (any PageCommandScrollArbiter)?
    /// The Command scroll from a page window held while its page is asked (`LayoutRootView+PageScroll`).
    var pageProbe: PageProbe?
    /// The task that asks the page for ``pageProbe``; tests await it.
    var pageProbeTask: Task<Void, Never>?
    /// Stops waiting for the page at ``pageProbeDeadline``, on the layout's injected clock.
    let pageProbeTimer: DemandTimer
    /// How long a held Command scroll waits for its page's answer before the columns take it. A
    /// page that is not stuck answers within a frame or two.
    let pageProbeDeadline: Duration = .milliseconds(120)
    var pageProbeGeneration: UInt64 = 0
    /// The last wheel answer of a page window, reused for the notches of one spin.
    var wheelPageAnswer: WheelPageAnswer?
    /// The pane the pointer was last over (`layout.focusFollowsMouse` hover): focus moves
    /// only when the pointer enters another pane, so a keyboard move is not undone by a
    /// small pointer twitch inside the pane it left.
    var hoveredPane: PaneID?
    /// Delivers pointer moves for focus-follows-mouse (owner: self).
    private var hoverTrackingArea: NSTrackingArea?
    /// How far the pointer has moved since the focus ring was earned (``handlePointerTravel(_:)``).
    var pointerTravelSinceRing: CGFloat = 0
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
    /// Work waiting for the layout to be still (``whenStill(_:on:_:)``), by key, with the queue it runs on.
    var stillWork: [String: (queue: FrameBatchQueue, work: @MainActor () -> Void)] = [:]
    /// Work waiting for its changes to settle (``whenSettled(_:after:on:_:)``), by key, with its timer.
    var settlingWork: [String: (timer: DemandTimer, queue: FrameBatchQueue, work: @MainActor () -> Void)] = [:]

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
    /// The right-click menu of split `SplitID`'s divider (Insert New, Hide or Show Divider), asked when the
    /// person right-clicks its grab band; nil: no menu.
    public var dividerMenu: ((SplitID) -> NSMenu?)? {
        get { context.dividerMenu }
        set { context.dividerMenu = newValue }
    }
    /// Whether a split or a pane close holds the terminals' grids now (``onTerminalGridHold``).
    public var holdsTerminalGrids: Bool { !context.gridHoldScreens.isEmpty }

    /// Everything the view reads from the model, observed as one value.
    struct Snapshot: Equatable, Sendable {
        var screens: [LayoutScreen]
        var activeScreen: ScreenID?
        var focused: PaneID?
        var focusRingEarned: Bool
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
    /// `scrollbarClock` runs the strip scrollbar's `auto` fade-out deadline and the wait for a
    /// page's Command scroll answer; tests inject a manual clock.
    /// `scrollFocusSignals` feeds focus-follows-mouse (`layout.focusFollowsMouse`);
    /// tests inject fixed values.
    /// `pageCommandScroll` asks a web page whether it keeps a Command scroll
    /// (`layout.pagesHandleCommandScroll`); nil gives every Command scroll to the layout.
    public init(model: LayoutModel, contentProvider: any LayoutPaneContentProvider,
                scrollbarClock: any Clock<Duration> = ContinuousClock(),
                scrollFocusSignals: ScrollFocusSignals = ScrollFocusSignals(),
                pageCommandScroll: (any PageCommandScrollArbiter)? = nil, hiddenScreens: FrameBatchQueue? = nil) {
        self.model = model
        hiddenScreenQueue = hiddenScreens
        self.scrollFocusSignals = scrollFocusSignals
        self.pageCommandScroll = pageCommandScroll
        self.pageProbeTimer = DemandTimer(owner: "layout.page-command-scroll", clock: scrollbarClock)
        self.context = LayoutViewContext(model: model, provider: contentProvider, scrollbarClock: scrollbarClock)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        context.window = { [weak self] in self?.window }
        context.requestFrames = { [weak self] in self?.driver.start() }
        driver.onFrame = { [weak self] dt in self?.advanceFrame(dt) ?? false }
        driver.onSettle = { [weak self] in _ = self?.landMotion() }
        context.overlayNeedsSync = { [weak self] in self?.setNeedsOverlaySync() }
        context.userMotionStepped = { [weak self] in self?.setLayoutInMotion(true) }
        context.userMotionEnded = { [weak self] in
            guard let self, !self.screenViews.values.contains(where: \.hasMotion), !self.driver.isRunning else { return }
            self.setLayoutInMotion(false)
        }
        context.gridHoldDidChange = { [weak self] held in self?.onTerminalGridHold?(held) }
        highlight.needsFrame = { [weak self] in self?.driver.start() }
        overlayPlane.addSubview(highlight)
        addSubview(overlayPlane)
        registerForDraggedTypes([LayoutTabDrag.pasteboardType, .URL])
        sync(snapshot())
        observe()
        #if DEBUG || CMUX_BENCH_HOOKS
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
        handlePointerTravel(abs(event.deltaX) + abs(event.deltaY))
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

    /// ``navigationFrames`` of the screen that holds `pane`, active or not: a hidden screen view keeps
    /// its geometry at the root's size, so what opens beside a pane on a screen the person switched
    /// away from reads that screen's layout (RightColumn).
    public func navigationFrames(ofScreenContaining pane: PaneID) -> [PaneID: CGRect] {
        guard let screen = model.screen(containing: pane), let view = screenViews[screen.id] else { return [:] }
        return view.navigationFrames
    }

    /// The width `pane`'s content rests at in the layout this view shows: its frame in the geometry its
    /// screen's springs head for (the same geometry ``navigationFrames(ofScreenContaining:)`` reads),
    /// less the pane padding. A split's or a close's panes read their final widths from the turn the
    /// layout changes, not what a running spring shows: the source of a split keeps its old width until
    /// the spring lands, and the new pane starts as a zero-width sliver (review of #29787 at 29861047).
    /// No layout pass: the geometry is computed when the layout syncs. Nil for a pane no screen view
    /// lays out, or one not sized yet.
    public func restingContentWidth(of pane: PaneID) -> CGFloat? {
        guard let screen = model.screen(containing: pane), let view = screenViews[screen.id], view.bounds.width > 0,
              let cell = view.baseGeometry.panes[pane] else { return nil }
        let width = PaneChromeGeometry.contentRect(forCell: CGRect(origin: .zero, size: cell.size), style: context.style).width
        return width > 0 ? width : nil
    }

    /// Displayed frame of `pane` in this view's coordinates (active screen only).
    public func frame(of pane: PaneID) -> CGRect? {
        guard let active = model.activeScreenID, let view = screenViews[active], let rect = view.displayedFrame(of: pane) else { return nil }
        return convert(rect, from: view)
    }

    // MARK: Observation

    private func snapshot() -> Snapshot { Snapshot(model) }

    private func observe() {
        let model = model
        observationTask = Task { [weak self] in
            for await snapshot in ObservationStream({ Snapshot(model) }) {
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

    /// Makes the first hidden screen still waiting (``deferredScreens``): its view, hidden at its place with its
    /// panes laid out at rest, as one made with the shown screen was. Its first show finds it made.
    /// False when none waits.
    @discardableResult
    public func mountDeferredScreen() -> Bool {
        guard let id = deferredScreens.first else { return false }
        mountingScreen = id
        defer { mountingScreen = nil }
        sync(snapshot())
        return true
    }

    /// Mirrors the model now for the window's next frame tick (a keyboard resize press, FRAME OWNER S1B): the springs
    /// get their targets in this turn, so the next display frame moves, but nothing is presented, laid out, announced to
    /// the content or synced to the overlay here. The next tick presents once (`advanceFrame`), and it is asked for.
    /// The key's own turn stays a model change. A root that runs
    /// no frames (parked, out of its window) syncs as ``syncWithModel()`` does. A screen the change did not put on a
    /// spring (Reduce Motion, pane animations off: its frames snapped) is asked to present in this turn. When the snap
    /// resizes a pane's host, that screen gives the host its size ahead in this turn and presents at the next frame
    /// tick (``ScreenContentView/holdsSnapForContent(keyPress:)``, #37330), so `applyPresentation` here returns at once. Only a
    /// snap that resizes no host presents in this turn.
    public func syncWithModelForNextFrame() {
        guard isLive, driver.isAttached else { return syncWithModel() }
        let held = context.holdsPresentations
        let before = lastSnapshot
        context.holdsPresentations = true
        syncWithModel()
        context.holdsPresentations = held
        let waiting = screenViews.values.filter(\.frameInput.presentationWaiting)
        let snapped = waiting.filter { !$0.hasMotion }
        for view in snapped { view.applyPresentation() }
        if !snapped.isEmpty { flushOverlaySync() }
        if waiting.count > snapped.count { driver.start() }
        // A change of screen in the held turn (a close that removes the shown screen): when no frame tick follows it,
        // what follows the panes once per placed frame hears it here (`syncBatched` leaves it to the tick under a hold).
        if let before, lastSnapshot?.activeScreen != before.activeScreen, !driver.isRunning, !held { onFramePlaced?() }
    }

    var canAnimate: Bool { window != nil && driver.isAttached && !context.reduceMotion }

    /// ``sync(_:)``'s body (`LayoutRootView+AvoiderBatch`).
    func syncBatched(_ snapshot: Snapshot) {
        let previous = lastSnapshot
        lastSnapshot = snapshot
        // A newly earned ring, or the ring moving to another pane by key, measures pointer travel from
        // zero (``handlePointerTravel(_:)``).
        if snapshot.focusRingEarned, previous?.focusRingEarned != true || previous?.focused != snapshot.focused {
            pointerTravelSinceRing = 0
        }
        // Chrome (focus ring, dim) fades whenever motion is allowed; pane frames and the strip's
        // reveal move only with `ui.paneAnimations` (motion.md rule 9). A change of screen never animates.
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
            $0.focused != snapshot.focused || $0.focusRingEarned != snapshot.focusRingEarned
                || $0.dimsInactive != snapshot.dimsInactive || $0.attention != snapshot.attention
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
        let waited = Set(deferredScreens)
        for screen in snapshot.screens {
            let isActive = screen.id == snapshot.activeScreen
            let view: ScreenContentView
            var isNew = false
            if let existing = screenViews[screen.id] {
                view = existing
            } else if defersHiddenScreens, !isActive, screen.id != mountingScreen,
                      before[screen.id]?.layout == screen.layout || !screen.layout.panes.contains(where: { context.hosts[$0] != nil }) {
                // Made when it first shows, or at idle (`deferredScreens`). One that takes a pane another screen
                // mounts is made now, so that pane moves to it inside the window, as it did.
                continue
            } else {
                isNew = true
                view = ScreenContentView(screenID: screen.id, layout: screen.layout, context: context)
                // A waiting screen made for its first show starts hidden, as it would have been made with the
                // shown one: its first pass lands at once and the switch below shows it at rest.
                view.isHidden = !isActive || waited.contains(screen.id)
                // At its size and in the window before its one first pass (`update(layout:)` below): that pass takes
                // its panes' hosts, so a pane the old screen shows moves inside the window, never out. Neither the size
                // nor the join lays it out (`ScreenContentView.setFrameSize`, `viewDidChangeBackingProperties`).
                view.frame = bounds
                if overlayPlane.isHome {
                    addSubview(view, positioned: .below, relativeTo: overlayPlane)
                } else {
                    addSubview(view)
                }
                screenViews[screen.id] = view
            }
            // Only a screen shown before and after this sync animates. A hidden one lands at once: frames step only
            // the screens shown (`advanceFrame`), so a spring started there (a restore, a daemon echo) froze its panes
            // mid-motion, their content held wider than the pane and pinned to its edge (Leo 2026-10-21). The screen
            // a switch shows (below) shows at rest, its panes, camera and chrome where this sync puts them, and the
            // one it hides starts no motion nobody sees. A screen whose view is made in this sync (a reopened, duplicated
            // or restored screen that comes with the change that shows it) was not shown before it either: a center or a
            // reveal request in the same change lands at once, not on a camera spring after the screen shows.
            let staysShown = isActive && !view.isHidden && !isNew
            // The screen this sync shows lays out at the root's size first, when a resize while it was hidden left that
            // for its show (`needsReconcileOnShow`): its scroll sync and a center or a reveal request below run on the
            // geometry it shows with. Left to `viewDidUnhide`, that layout ran after them and moved the camera off
            // the place the request put it.
            if isActive, view.isHidden { view.reconcileIfDeferred() }
            // A waiting screen's first pass lands at once, as a screen made with the shown one did (no previous sync).
            let landsAtOnce = isNew && waited.contains(screen.id)
            let old = before[screen.id]
            view.hiddenDividers = screen.hiddenDividers
            // A zoomed pane shows full size over its canvas (canvas-layout.md).
            let canvas = screen.zoomed ? nil : snapshot.canvases[screen.id]
            let layoutChanged = isNew || old?.layout != screen.layout || old?.zoomed != screen.zoomed || sharedChanged
                || view.holdsRowDragPreview || canvas != (old?.zoomed == true ? nil : previous?.canvases[screen.id])
            if layoutChanged {
                let structureChanged = old.map { !$0.layout.hasSameStructure(as: screen.layout) } ?? true
                // An explicit equalize (same structure, new ratios) springs whenever motion is allowed (Lawrence
                // 2026-10-16); the sizing after a split or close, and released drags, follow `ui.paneAnimations`.
                let reflows = chromeAnimated && !structureChanged && !snapshot.gestureActive && model.animatesReflow
                if view.update(layout: screen.layout, zoomed: screen.zoomed, canvas: canvas,
                               animated: (animated || reflows) && staysShown, snapWaitsForFrame: isLive && driver.isAttached) {
                    needsFrames = true
                }
                // The focus ring of a split's new pane appears with the pane; the focus flash still
                // runs, so the pane after a close or a link's new pane shows where focus went.
                view.updateChrome(focused: snapshot.focused, dimsInactive: snapshot.dimsInactive, attention: snapshot.attention,
                                  animated: chromeAnimated && !structureChanged && staysShown, flashAnimated: chromeAnimated && !landsAtOnce)
            } else if chromeChanged {
                // A focus move alone changes the chrome of two panes, the one left and the one focused: every
                // other pane keeps its ring, dim and tab emphasis (O(2), not O(panes); speed-of-sound 3.2).
                let focusMoveOnly = previous.map {
                    !sharedChanged && $0.dimsInactive == snapshot.dimsInactive && $0.attention == snapshot.attention
                } ?? false
                // The focus flash is an event, not a state: it still runs on the screen a switch shows (a focus
                // nobody clicked shows where it went); the ring and dim of that screen are at rest when it shows.
                view.updateChrome(focused: snapshot.focused, dimsInactive: snapshot.dimsInactive, attention: snapshot.attention,
                                  animated: chromeAnimated && staysShown, flashAnimated: chromeAnimated,
                                  only: focusMoveOnly ? Set([previous?.focused, snapshot.focused].compactMap { $0 }) : nil)
            }
            // A changed layout or focus reaches the scroll reducer: it anchors
            // the camera on layout changes, reveals focus, and springs back
            // after a close. A focus move, a switch, a center mode or a gesture reaches only the screen shown and
            // the one a switch hides (O(2), not O(screens): a focus move ran a scroll sync and a presentation pass of
            // every mounted screen). A screen that stays hidden has no camera to move; it gets the focus and the mode
            // in the sync that shows it (a switch is a `scrollChanged`), as a screen mounted at idle does.
            if layoutChanged || (scrollChanged && (isActive || screen.id == previous?.activeScreen)) {
                let focused = snapshot.focused.flatMap { screen.layout.contains($0) ? $0 : nil }
                let source: ColumnFocusSource = previous?.focused != snapshot.focused ? model.lastFocusSource : .programmatic
                // Only a snap that stands in for Reduce Motion's spring shows the
                // scrollbar, not one at launch or while out of the window.
                // Only the shown screen's camera asks for frames: the one a switch hides lands its camera when it
                // hides (`showScreen`), so a spring it had in flight does not hold the switch for a frame tick.
                if view.syncScroll(focused: focused, source: source, mode: snapshot.centerMode,
                                   animated: previous != nil && !landsAtOnce && staysShown && canAnimate && context.animatesPaneLayout,
                                   reveals: !snapshot.gestureActive,
                                   showsScrollbarOnSnap: previous != nil && !landsAtOnce && window != nil && driver.isAttached),
                   isActive {
                    needsFrames = true
                }
            }
            if let request = snapshot.centerRequest, request != previous?.centerRequest, screen.layout.contains(request.pane),
               view.center(request.pane, animated: animated && !landsAtOnce && staysShown) {
                needsFrames = true
            }
            if let request = snapshot.revealRequest, request != appliedReveal, screen.layout.contains(request.pane) {
                appliedReveal = request
                if view.center(request.pane, animated: animated && !landsAtOnce && staysShown, reveal: true) { needsFrames = true }
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
        }

        deferredScreens = defersHiddenScreens ? snapshot.screens.compactMap { screenViews[$0.id] == nil ? $0.id : nil } : []
        if !deferredScreens.isEmpty { mountDeferredScreensWhenIdle() }

        // Screen switch: the new screen shows and the old one hides in this turn, at rest (no transition).
        if previous?.activeScreen != snapshot.activeScreen { showScreen(snapshot.activeScreen) }

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
        let switched = previous.map { $0.activeScreen != snapshot.activeScreen } ?? false
        if needsFrames { driver.start() }
        // A divider drag moves panes in this sync with no frame tick after it: what follows the panes once per placed
        // frame (shortcut hint chips) hears it here, as from a tick; a sync in a tick's input hears it from that tick.
        // So does a change of screen: other panes show, at rest, and no frame runs after it.
        else if snapshot.gestureActive || switched, !context.holdsPresentations { onFramePlaced?() }
        // A change that starts springs (a split, a close) is in motion from the frame it lands in.
        if needsFrames && driver.isRunning { setLayoutInMotion(true) }
    }

    // MARK: Frames

    /// The final layout now, in one pass: Reduce Motion turned on mid-flight, or the window went out
    /// of sight (`DisplayLinkDriver.motionSettle`). `waitsForContent`: a Reduce Motion frame tick, in which a key press's
    /// held snap may wait for its terminals' programs (``LayoutFrameInput/presentWaiting(waitsForContent:)``); returns
    /// whether one still waits.
    @discardableResult
    func landMotion(waitsForContent: Bool = false) -> Bool {
        defer { onFramePlaced?() }
        // A drag's newest pointer first, as in a frame (its window went out of sight mid-drag): it lands in this one pass.
        let input = LayoutFrameInput(root: self)
        input.apply()
        for view in screenViews.values {
            if view.hasMotion || view.resizeGesture == .landing { view.settleMotion() }
            view.settleCanvasCamera()
        }
        let snapWaits = input.presentWaiting(waitsForContent: waitsForContent)
        highlight.settle()
        updateVisibility()
        flushOverlaySync()
        setLayoutInMotion(false)
        return snapWaits
    }

    /// ``advanceFrame(_:)``'s body (`LayoutRootView+AvoiderBatch`).
    func advanceFrameBatched(_ dt: Double) -> Bool {
        // The frame's input first (a drag's newest pointer, `LayoutFrameInput`): its pass waits for this frame's one pass.
        let input = LayoutFrameInput(root: self), dragging = input.keepsTicking()
        input.apply()
        // A released resize drag whose layout the observation has not applied yet: apply it before this
        // frame, so the frame that ends the drag for the pane contents is the release's (`ScreenContentView+ResizeGesture`).
        if !model.isGestureActive, screenViews.values.contains(where: { $0.resizeGesture == .releasing }) {
            syncWithModel()
            // Nothing new to apply: the screens already show the model.
            for view in screenViews.values where view.resizeGesture == .releasing { view.resizeGestureModelSynced(gestureActive: false) }
        }
        // Reduce Motion (or the no-animation switch) turned on mid-flight: the final layout now, no more frames but a drag's.
        if context.reduceMotion {
            // A key press's snap that waits for its terminals' programs needs the next tick (RESIZE P0 20).
            let snapWaits = landMotion(waitsForContent: true)
            return dragging || snapWaits
        }
        defer { onFramePlaced?() }
        // One motion policy per frame (it reads the animation settings), not one per spring.
        let policy = Motion.panes.policy
        var moving = false, panning = false
        for view in screenViews.values where !view.isHidden {
            // Pan events that waited in the last frame show first, then the springs step.
            if view.displayFrameBegan() { panning = true }
            if view.step(dt, policy: policy) { moving = true }
            if view.stepCanvasCamera(dt, policy: policy) { moving = true }
        }
        let snapWaits = input.presentWaiting()
        if highlight.step(dt) { moving = true }
        updateVisibility()
        // A pan with the finger down is layout motion (`userMotionActive`): a frame tick during it
        // is not its landing, so what waits for the landing (page windows, catcher panels) waits on.
        let gesturing = screenViews.values.contains(where: \.userMotionActive)
        // The frame that lands still syncs as part of the motion; observers hear it ended after it.
        if moving || gesturing { setLayoutInMotion(true) }
        flushOverlaySync()
        if !moving && !gesturing { setLayoutInMotion(false) }
        // A strip pan and a divider drag keep the ticks a little after each event (`ScreenContentView.panTickTail`);
        // a gesture with a still pointer needs none after that.
        return moving || panning || dragging || snapWaits
    }

    /// Tells the layout motion observers when the first spring starts and when the last one lands.
    func setLayoutInMotion(_ moving: Bool) {
        // After the flag: the landing's still work sees a still layout (a drag's release with no spring ends here too).
        defer { if !moving { runStillWork() } }
        guard moving != isLayoutInMotion else { return }
        isLayoutInMotion = moving
        for block in layoutMotionObservers.values { block(moving) }
        // The landing frame synced while still in motion: the window hears the rest now (catchers).
        if !moving { reportInteractiveRects() }
    }

    func updateVisibility() {
        var visible: Set<PaneID> = []
        var keepAlive: Set<PaneID> = []
        let reads = model.layoutPassReads
        if isLive, let active = reads.activeScreenID, let view = screenViews[active] {
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
        // content attaches. Among the panes of one kind of change, the focused pane goes first, then
        // layout order: the app makes one new surface per frame in this order, and the pane the
        // person types into must not wait behind the others (REOPEN-F4: in a Set's hash order, the
        // first key after a reopen was lost in 10 of 15 cycles).
        let focused = reads.focusedPane
        let order = Dictionary((reads.activeScreen?.layout.panes ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func place(_ pane: PaneID) -> (Int, Int, String) { (pane == focused ? 0 : 1, order[pane] ?? .max, pane.rawValue) }
        for (pane, presence) in changes.sorted(by: { $0.1.rank != $1.1.rank ? $0.1.rank < $1.1.rank : place($0.0) < place($1.0) }) {
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
        fitScreensToBounds()
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
            // Settled: the motion ended for its observers (the window's divider catchers and page geometry, the still
            // work), as a landing frame ends it. Without this the flag stayed set through the park, nothing landed
            // after it, and the catchers never moved off the old dividers (Leo 2026-11-06: a closed split's pane
            // stayed unclickable).
            setLayoutInMotion(false)
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
            if !deferredScreens.isEmpty { mountDeferredScreensWhenIdle() }
            if screenViews.values.contains(where: { $0.hasMotion || $0.activeDrag?.waiting == true }) { driver.start() }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .mouseMoved]) { [weak self] event in
                self?.handleMonitored(event) ?? event
            }
        }
        updateVisibility()
        // The layout changes it saw while parked: one overlay sync now.
        if live { flushOverlaySync() }
    }

}

extension LayoutRootView: ParkingObserver {}

extension LayoutRootView.Snapshot {
    /// Everything the view reads from `model` now; in `observe`, the observation tracks every property it reads.
    init(_ model: LayoutModel) {
        self.init(screens: model.screens, activeScreen: model.activeScreenID, focused: model.focusedPane,
                  focusRingEarned: model.focusRingEarned, dimsInactive: model.dimsInactivePanes,
                  style: model.style, gestureActive: model.isGestureActive, centerRequest: model.centerRequest,
                  revealRequest: model.revealRequest, centerMode: model.centerFocusedColumn, attention: model.attention,
                  scrollbar: model.stripScrollbar, rowOps: model.acceptsRowOps, canvases: model.canvases)
    }
}
