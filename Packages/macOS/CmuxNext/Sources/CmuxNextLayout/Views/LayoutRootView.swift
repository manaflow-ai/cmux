public import AppKit
import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextInput
public import CmuxNextSignposts
public import CmuxNextWakeups
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
    /// The screen switch the render server still slides (`LayoutRootView+Screens.swift`).
    var screenSwitch = ScreenSwitchFlight()
    /// Saved cameras of screens not built yet (`restoreScroll`), taken when each is.
    var pendingScreenScrolls: [ScreenID: LayoutScreenScroll] = [:]
    let highlight = DropHighlightView()
    /// The root's render-server motion variants (screen switches, the drop highlight) and the
    /// `motion.renderServer` switch (`LayoutRootView+Motion.swift`).
    var motionBackends: MotionBackends<LayoutRootView>
    /// Non-interactive overlays (rings, dims, drop highlight). See
    /// `OverlayPlane`: the window may lift it above content child windows.
    public private(set) lazy var overlayPlane = OverlayPlane(home: self)
    weak var planeHost: (any OverlayPlaneHosting)?
    var reportedInteractiveRects: [CGRect] = []
    var reportedDividerMouseAreas: [LayoutMouseArea] = []
    /// ``isInLayoutMotion`` at the last report: its end is reported even when no rect changed.
    var reportedLayoutMotion = false
    let driver = DisplayLinkDriver()
    /// This window's `motion.frame` and `motion.run` signposts.
    let motionTrace: LayoutMotionTrace
    /// Told of each plan this root applies on a shown screen, until its commit (``PlanApplyTurn``).
    private let planApplies: PlanApplyTurn
    private var modelWatch: FrameObservation<Snapshot>?
    /// The attention ring's look (`AttentionHighlightLook`, Debug Settings): one watch for every pane's
    /// overlay, applied once per frame (made in `init`).
    private var attentionLookWatch: FrameObservation<AttentionHighlightLook>?
    /// The app's one input tap (nil: nothing routes the app's events to this root; tests call the
    /// routing directly).
    let inputTap: InputEventTap?
    /// The scroll, magnify and button intercept (``InputEventTap/InterceptOrder/layout``), held while
    /// the root is live (`setLive`).
    private var inputIntercept: InputSubscription?
    /// The pointer-move intercept held while a strip shows away from its laid-out place
    /// (``updatePointerLanding()``).
    private var pointerLanding: InputSubscription?
    /// Key-window subscriptions on the current window's ``WindowEvents`` (`observeKeyWindow()`).
    var keyWindowObservers: [EventSubscription] = []
    private var lastSnapshot: Snapshot?
    /// The last reveal request applied; a newer one waits until its pane is in a screen's layout.
    private var appliedReveal: ColumnCenterRequest?
    /// Each screen's last automation-caused structural change, in ``burstClock`` seconds (``landsAtOnce(_:steps:)``).
    private var lastAutomationChange: [ScreenID: CFTimeInterval] = [:]
    /// The clock of automation bursts; tests set their own.
    var burstClock: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// Structural changes of automation bursts that landed with no spring, cumulative (diagnostics, tests).
    private(set) var automationBurstSnaps = 0
    private var presence = PanePresenceReport()
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
    /// Focus-follows-mouse's hover moves on the window's frames (``mouseMoved(with:)``).
    private(set) lazy var hoverFocus = PointerFrameHover(owner: "LayoutRootView.focusFollowsMouse", view: self) { [weak self] point in
        _ = self?.focusPaneForPointerHover(at: point)
    }
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
    /// `input` is the app's one input tap: while the root is live, its scroll, magnify and button
    /// routing is an intercept there. The App passes its tap; nil only where no event dispatches.
    /// `mainWork` is the app's main-thread scheduler: the Debug Settings looks of the panes' overlays
    /// and the drop highlight follow through it.
    /// `motionSignposter` takes the window's `motion.frame` and `motion.run` intervals; tests pass one on
    /// their own trace runtime.
    /// `hiddenWork` is the app's count of work done while off screen (its passes while ``isOffScreen``); nil
    /// where nobody reads it.
    public init(model: LayoutModel, contentProvider: any LayoutPaneContentProvider,
                scrollbarClock: any Clock<Duration> = ContinuousClock(),
                scrollFocusSignals: ScrollFocusSignals = ScrollFocusSignals(),
                rendersMotionOnServer: @escaping () -> Bool = { LayoutTunables.motionRenderServer.value },
                input: InputEventTap? = nil, mainWork: MainWorkScheduler,
                motionSignposter: Signposter = .motion, hiddenWork: HiddenLayoutWork? = nil) {
        self.model = model
        inputTap = input
        self.hiddenWork = hiddenWork
        motionTrace = LayoutMotionTrace(signposter: motionSignposter)
        planApplies = mainWork.planApplies
        self.scrollFocusSignals = scrollFocusSignals
        self.context = LayoutViewContext(model: model, provider: contentProvider, scrollbarClock: scrollbarClock,
                                         rendersMotionOnServer: rendersMotionOnServer)
        self.motionBackends = MotionBackends(LayoutRootView.renderServerMotions, renderServer: rendersMotionOnServer)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        context.requestFrames = { [weak self] in self?.driver.start() }
        driver.onFrame = { [weak self] dt in self?.advanceFrame(dt) ?? false }
        context.wireOverlaySync(to: self)
        context.userMotionStepped = { [weak self] in self?.setLayoutInMotion(true) }
        context.renderSpringsLanded = { [weak self] in self?.updateVisibilityIfPlanChanged() }
        context.userMotionEnded = { [weak self] in
            guard let self, !self.screenViews.values.contains(where: \.hasMotion), !self.driver.isRunning,
                  !self.screenSwitch.isInFlight else { return }
            self.setLayoutInMotion(false)
            // The render server's springs landed after the CPU's last frame: the run rests here.
            if !self.rendersMotion { self.motionTrace.endRun() }
        }
        context.renderMotionBegan = { [weak self] in self?.motionTrace.beginRun(on: self?.window.map(FrameScheduler.forWindow)) }
        context.gridHoldDidChange = { [weak self] held in self?.onTerminalGridHold?(held) }
        // The window adopts the plane exactly while it shows content child windows (`OverlayPlaneHosting`).
        context.childWindowContentShows = { [weak self] in self.map { !$0.overlayPlane.isHome } ?? false }
        context.stripMovedDidChange = { [weak self] in self?.updatePointerLanding() }
        overlayPlane.onHomeChange = { [weak self] in self?.overlayPlaneHomeDidChange() }
        context.stripClipsDidChange = { [weak self] in if let self { planeHost?.paneShapesDidChange(overlayPlane) } }
        highlight.needsFrame = { [weak self] in if let self, highlightStepsOnFrames { driver.start() } }
        followLooks(on: mainWork)
        overlayPlane.addSubview(highlight)
        addSubview(overlayPlane)
        // Pointer moves for focus-follows-mouse.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        registerForDraggedTypes([LayoutTabDrag.pasteboardType, .URL])
        sync(snapshot())
        observe(on: mainWork)
        #if DEBUG || CMUX_BENCH_HOOKS
        ScreenContentView.registerMotionSampler()
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// One watch per root for the panes' attention look, not one per pane: a change reaches every
    /// overlay in one apply, as Chrome's `Widget::ThemeChanged` reaches its views
    /// (ui/views/widget/widget.cc). A pane made later reads the look when its overlay is made.
    private func followLooks(on mainWork: MainWorkScheduler) {
        highlight.follow(on: mainWork)
        // node-free: the root has no VisibilityNode; the apply only recolors the panes' rings.
        attentionLookWatch = FrameObservation(owner: "Layout.attentionLook", delivery: .visible(nil), on: mainWork) {
            AttentionHighlightLook.tunable.value
        } onChange: { [weak self] look in
            guard let self else { return }
            for host in self.context.hosts.values { host.chrome.setAttentionLook(look) }
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            modelWatch?.cancel()
            inputIntercept?.cancel()
            pointerLanding?.cancel()
            for subscription in keyWindowObservers { subscription.cancel() }
            driver.detach()
            motionTrace.endRun()
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
        return convert(rect, from: view)
    }

    // MARK: Observation

    private func snapshot() -> Snapshot { Self.snapshot(of: model) }

    private static func snapshot(of model: LayoutModel) -> Snapshot {
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

    /// One sync per burst of model changes, before the changes' run loop pass commits its frame (a person's in
    /// their input's response pass), as Blink runs its lifecycle once per frame (page_animator.cc).
    private func observe(on mainWork: MainWorkScheduler) {
        let model = model
        modelWatch = FrameObservation(owner: "Layout.modelSync", delivery: .sameTurn("syncWithModel and the frame driver read the synced screens in the change's turn"),
                                      on: mainWork) { Self.snapshot(of: model) } onChange: { [weak self] snapshot in
            guard let self, snapshot != self.lastSnapshot else { return }
            self.sync(snapshot)
        }
    }

    /// Mirrors the model now (a pending observed change first) instead of on the observation's apply.
    /// The App calls it after applying a daemon tree, so the frame that
    /// shows a workspace (or a split, close or new tab in it) already has
    /// its panes and tab strips; the observation then finds nothing new.
    public func syncWithModel() {
        modelWatch?.flushIfDirty()
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
        let automationSteps = model.takeAutomationSteps()
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
                if let saved = pendingScreenScrolls.removeValue(forKey: screen.id) { view.restoreScroll(saved) }
            }
            // One change turn per screen: every motion this change starts on it (layout, chrome, scroll,
            // center and reveal) starts before its render-server kinds take theirs and it lays out once.
            view.beginMotionTurn()
            var screenNeedsFrames = false
            let old = before[screen.id]
            // A zoomed pane shows full size over its canvas (canvas-layout.md).
            let canvas = screen.zoomed ? nil : snapshot.canvases[screen.id]
            let layoutChanged = isNew || old?.layout != screen.layout || old?.zoomed != screen.zoomed || sharedChanged
                || view.holdsRowDragPreview || canvas != (old?.zoomed == true ? nil : previous?.canvases[screen.id])
            // An automation burst's structural change takes the path `ui.animations.panes` off takes:
            // its panes, scroll and camera land in this frame, springs in flight included; chrome still fades.
            var landsAtOnce = false
            if layoutChanged {
                if isLive, !view.isHidden { planApplies.noteApplied() } // a shown plan commits in this turn
                let structureChanged = old.map { !$0.layout.hasSameStructure(as: screen.layout) } ?? true
                landsAtOnce = structureChanged && self.landsAtOnce(screen.id, steps: automationSteps[screen.id])
                // An explicit equalize (same structure, new ratios) springs whenever motion is allowed (Lawrence
                // 2026-10-16); the sizing after a split or close, and released drags, follow `ui.paneAnimations`.
                let reflows = chromeAnimated && !structureChanged && !snapshot.gestureActive && model.animatesReflow
                // A hidden screen lands at once: frames step only the screens shown (`advanceFrame`), so a
                // spring started there (a restore, a daemon echo) froze its panes mid-motion, their
                // content held wider than the pane and pinned to its edge (Leo 2026-10-21).
                if view.update(layout: screen.layout, zoomed: screen.zoomed, canvas: canvas,
                               animated: (animated || reflows) && !view.isHidden && !landsAtOnce) {
                    screenNeedsFrames = true
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
                                   animated: previous != nil && canAnimate && context.animatesPaneLayout && !landsAtOnce,
                                   reveals: !snapshot.gestureActive,
                                   showsScrollbarOnSnap: previous != nil && window != nil && driver.isAttached) {
                    screenNeedsFrames = true
                }
            }
            if let request = snapshot.centerRequest, request != previous?.centerRequest, screen.layout.contains(request.pane),
               view.center(request.pane, animated: animated && !landsAtOnce) {
                screenNeedsFrames = true
            }
            if let request = snapshot.revealRequest, request != appliedReveal, screen.layout.contains(request.pane) {
                appliedReveal = request
                if view.center(request.pane, animated: animated && !landsAtOnce, reveal: true) { screenNeedsFrames = true }
            }
            if view.endMotionTurn(needsFrames: screenNeedsFrames) { needsFrames = true }
        }

        for (id, view) in leaving {
            view.tearDown()
            view.removeFromSuperview()
            screenViews[id] = nil
            screenFrames[id] = nil
            lastAutomationChange[id] = nil
        }

        // Screen switch. One that does not spring shows its rest in this turn, the screens a switch
        // on the render server still slides included.
        var stoppedSwitch = false
        if previous?.activeScreen != snapshot.activeScreen {
            if !animated { stoppedSwitch = stopScreenSwitch() }
            let switching = switchScreens(from: previous?.activeScreen, to: snapshot.activeScreen, order: snapshot.screens.map(\.id),
                                          animated: animated)
            if endMotionTurn(needsFrames: switching) { needsFrames = true }
            applyScreenFrames()
        }

        updateVisibilityIfPlanChanged()
        overlayIsStale = true
        flushOverlaySync()
        // Pane padding or corners changed: pages drawn as child windows
        // re-read their clip shape (their frames may not have moved).
        if let previous, previous.style != snapshot.style { planeHost?.paneShapesDidChange(overlayPlane) }
        if needsFrames || snapshot.gestureActive { driver.start() }
        // A structural change that starts springs on the CPU: one motion.run until they rest (`advanceFrame`). One
        // the render server took opened it already (`context.renderMotionBegan`).
        if needsFrames, driver.isAttached { motionTrace.beginRun(on: window.map(FrameScheduler.forWindow)) }
        // A change that starts springs (a split, a close) is in motion from the frame it lands in.
        if needsFrames && driver.isRunning { setLayoutInMotion(true) } else if stoppedSwitch { endLayoutMotionIfSettled() }
    }

    /// Whether a structural change of `screen` lands with no spring, as part of an automation burst
    /// (`LayoutModel.snapsAutomationBursts`; `steps`: the panes its automation changes moved, nil
    /// when anyone else changed it). A burst moved several panes at once (commands coalesced into
    /// one apply), or comes within a split spring's time of the screen's last automation change
    /// (one command per frame), whose spring it would restart before it lands. A single automation
    /// change after a pause springs as a person's does.
    private func landsAtOnce(_ screen: ScreenID, steps: Int?) -> Bool {
        guard let steps else {
            lastAutomationChange[screen] = nil
            return false
        }
        let now = burstClock()
        let last = lastAutomationChange.updateValue(now, forKey: screen)
        guard steps > 1 || last.map({ now - $0 < Motion.panes.spring(.split).perceivedDuration }) == true else { return false }
        automationBurstSnaps += 1
        return true
    }

    // MARK: Frames

    /// One display tick: the window's `motion.frame`, and the end of its `motion.run` in the frame that rests
    /// (unless render-server springs still run: their landing ends it, `context.userMotionEnded`).
    ///
    /// - Returns: Whether the window needs another tick.
    func advanceFrame(_ dt: Double) -> Bool { // perf-hot: 4ms motion-frame
        let moving = motionTrace.frame(dt: dt, movedPanes: { movingPaneCount }) { stepFrame(dt) }
        planApplies.noteApplied() // the frame's step is a plan apply: it commits in this turn
        if !moving, !rendersMotion { motionTrace.endRun() }
        return moving
    }

    /// Panes the next frame moves in the screens shown: every pane of a screen whose frame springs (a screen
    /// switch), else the screen's own (`ScreenContentView.movingPaneCount`).
    private var movingPaneCount: Int {
        var count = 0
        for (id, view) in screenViews where !view.isHidden {
            let switching = screenFrames[id].map { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target } ?? false
            count += switching ? view.paneFrames.count : view.movingPaneCount
        }
        return count
    }

    /// Render-server springs have not landed: a screen switch's (``ScreenSwitchFlight``) or a screen's
    /// (`ScreenContentView.renderSpringsInFlight`).
    var rendersMotion: Bool { screenSwitch.isInFlight || screenViews.values.contains { $0.renderSpringsInFlight > 0 } }

    private func stepFrame(_ dt: Double) -> Bool {
        // Reduce Motion (or the no-animation switch) turned on mid-flight: the final layout now, no more frames.
        if context.reduceMotion {
            // A resampled pan's event that waited for this frame shows now, unresampled.
            for view in screenViews.values where !view.isHidden { view.presentFramePan(at: nil) }
            for view in screenViews.values where view.hasMotion { view.settleMotion() }
            stopScreenSwitch()
            for id in Array(screenFrames.keys) { screenFrames[id]?.snap() }
            applyScreenFrames()
            updateVisibilityIfPlanChanged()
            flushOverlaySync()
            setLayoutInMotion(false)
            return false
        }
        // One motion policy per frame (it reads the animation settings), not one per spring.
        let policy = Motion.panes.policy
        var moving = false, panning = false
        for view in screenViews.values where !view.isHidden {
            // Pan events that waited in the last frame show first (resampled at the frame's time), then the springs step.
            if view.displayFrameBegan(at: driver.frameTime) { panning = true }
            if view.step(dt, policy: policy) { moving = true }
        }
        // Only a switch the CPU steps places screens per frame; one on the render server placed them once.
        if screensStepping {
            let screenSpring = policy.spring(.screen)
            for id in Array(screenFrames.keys) {
                if screenFrames[id]?.advance(dt, parameters: screenSpring) == true { moving = true }
            }
            applyScreenFrames()
        }
        if highlightStepsOnFrames, highlight.step(dt) { moving = true }
        updateVisibilityIfPlanChanged() // a frame on the way changes no presence (`ScreenVisibilityPlan`)
        // A pan with the finger down is layout motion (`userMotionActive`): a frame tick during it
        // is not its landing, so what waits for the landing (page windows, catcher panels) waits on.
        let gesturing = screenViews.values.contains(where: \.userMotionActive)
        // The frame that lands still syncs as part of the motion; observers hear it ended after it.
        if moving || gesturing { setLayoutInMotion(true) }
        flushOverlaySync()
        // A switch on the render server ends the motion when it lands (`screenSwitchLanded`).
        if !moving && !gesturing && !screenSwitch.isInFlight { setLayoutInMotion(false) }
        // A strip pan that moves the frames keeps the ticks until its finger lifts
        // (`ScreenContentView.displayFrameBegan`); a pan on the motion container keeps them only resampled.
        return moving || panning
    }

    /// Tells the layout motion observers when the first spring starts and when the last one lands.
    func setLayoutInMotion(_ moving: Bool) {
        guard moving != isLayoutInMotion else { return }
        isLayoutInMotion = moving
        for block in layoutMotionObservers.values { block(moving) }
        guard !moving else { return }
        // The landing frame synced while still in motion: the window hears the rest now (catchers), and content
        // that follows its pane's place in the window hears it once (`PanePlacementFollowing`).
        reportInteractiveRects()
        for screen in screenViews.values where !screen.isHidden {
            for host in screen.displayedHosts { host.settlePlacement() }
        }
    }

    /// `updateVisibility()` calls (`debug.layout_counters` `update_visibility`): a spring wants <= 2 (p03-rendering DC2).
    public var visibilityUpdates: UInt64 { presence.passes }

    /// A visibility pass when the active screen's plan (`ScreenVisibilityPlan`) changed since the last one. A display
    /// frame asks this: the check builds no plan (``PanePresenceReport/isCurrent(for:)``).
    func updateVisibilityIfPlanChanged() { // perf-hot: 4ms motion-frame
        if !presence.isCurrent(for: visibilityScreen) { updateVisibility() }
    }

    /// The screen a visibility pass reads: the active one, while the root is live.
    private var visibilityScreen: ScreenContentView? { isLive ? model.activeScreenID.flatMap { screenViews[$0] } : nil }

    func updateVisibility() {
        guard let changes = presence.pass(visibilityScreen) else { return }
        model.reportVisiblePanes(presence.visible, keepAlive: presence.keepAlive)
        for (pane, now) in changes { context.provider?.panePresenceDidChange(pane, presence: now) }
    }

    // MARK: Layout and window

    /// Layout passes of every root (`debug.layout_counters`): a window resize lays out the shown
    /// workspace only; a parked one keeps its frame until it shows again.
    public static var layoutPasses: UInt64 = 0
    /// Whether its workspace is off screen (parked on no screen), set by the workspace's controller: its passes
    /// then count in ``HiddenLayoutWork/layoutPasses``.
    public var isOffScreen = false
    private let hiddenWork: HiddenLayoutWork?
    /// Panes whose chrome (ring, dim, tab emphasis) a sync re-ran, all windows (`debug.layout_counters`).
    public static var paneChromeUpdates: UInt64 = 0

    override public func layout() {
        super.layout()
        Self.layoutPasses &+= 1
        if isOffScreen { hiddenWork?.noteLayoutPass() }
        for (id, view) in screenViews {
            if view.frame.size != bounds.size { view.setFrameSize(bounds.size) }
            if var frame = screenFrames[id] {
                // Only the size follows the root at once. A screen switch in flight (its x and alpha springs)
                // goes on from where it shows: snapping x and y here ended the slide in whatever frame a layout
                // pass came, both screens jumping to the middle (`switchScreens` sets the slide's targets).
                frame.width.snap(to: bounds.width)
                frame.height.snap(to: bounds.height)
                screenFrames[id] = frame
            }
        }
        applyScreenFrames()
        updateVisibilityIfPlanChanged()
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

    // visibility-walk-allow: read once per window move, unhide or park to set isLive; per-frame and per-event readers read isLive
    private var isShown: Bool { window != nil && !isHiddenOrHasHiddenAncestor && !isParkedOrHasParkedAncestor }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== window { setLive(false) }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hoverFocus.frames = (window as? any HoverFrameInputHosting)?.hoverFrameInput
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
        inputIntercept?.cancel()
        inputIntercept = nil
        pointerLanding?.cancel()
        pointerLanding = nil
        driver.detach()
        if !live {
            for view in screenViews.values { view.settleMotion() }
            // No frame shows a parked root: a switch in flight lands now, its old screen hidden.
            if stopScreenSwitch() {
                applyScreenFrames()
                endLayoutMotionIfSettled()
            }
            motionTrace.endRun()
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
            if screenViews.values.contains(where: \.hasMotion) || screensStepping { driver.start() }
            inputIntercept = subscribeInput()
            updatePointerLanding()
        }
        updateVisibilityIfPlanChanged()
        // The layout changes it saw while parked: one overlay sync now.
        if live { flushOverlaySync() }
    }

}

extension LayoutRootView: ParkingObserver {}

// MARK: Pointer input lands a moved strip

extension LayoutRootView {
    /// Lays every strip that shows away from its laid-out place out where it shows
    /// (`ScreenContentView.landStripWhereItShows()`), before a press, a pointer move, a new scroll
    /// gesture or a wheel notch reaches a view. O(screens); nothing when no strip shows moved.
    func landStripsWhereTheyShow() {
        for view in screenViews.values where view.showsPanMoved { view.landStripWhereItShows() }
    }

    /// Holds a pointer-move intercept exactly while a strip shows moved: a move then lands it before
    /// AppKit reads its tracking areas and cursor rects at the views' frames. The press and the scroll
    /// routes land it in the root's own intercept (``handleMonitored(_:)``). Called when a strip starts
    /// or stops showing moved and when the root goes live, so a strip at rest costs pointer moves nothing.
    func updatePointerLanding() {
        let moved = isLive && screenViews.values.contains { $0.showsPanMoved }
        if moved, pointerLanding == nil, let window {
            // Scoped to the root's window (a live root leaves its window only through `setLive(false)`,
            // which cancels this): another window's moves run no closure; its page windows' do, and pass.
            pointerLanding = inputTap?.subscribe(class: .pointerMove, phase: .intercept(order: .layout), window: .window(window)) { [weak self] event in
                if let self, event.window === self.window { self.landStripsWhereTheyShow() }
                return .pass
            }
        } else if !moved, let subscription = pointerLanding {
            subscription.cancel()
            pointerLanding = nil
        }
    }

    /// The overlay plane moved between this view and the window's overlay panel: content child
    /// windows came or went. While they show, a strip pans its frames (`ScreenContentView.pansOnContainer`),
    /// so one that shows moved lands where it shows now and a page window placed from its host's frame
    /// matches it.
    func overlayPlaneHomeDidChange() {
        guard !overlayPlane.isHome else { return }
        landStripsWhereTheyShow()
    }
}
