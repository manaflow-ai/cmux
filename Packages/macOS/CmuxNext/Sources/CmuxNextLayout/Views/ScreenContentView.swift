import AppKit
import CmuxNextDesign
/// Renders one screen: a split tree, or a horizontally scrolling strip of
/// columns. Pane and divider frames are springs in content space (``LayoutFrames``); the
/// displayed frame subtracts the scroll offset.
final class ScreenContentView: NSView {
    let screenID: ScreenID
    let context: LayoutViewContext
    private(set) var layout: ScreenLayout
    /// The layout is one zoomed pane (`LayoutScreen.zoomed`).
    private(set) var zoomed = false
    /// Frames before the rows' vertical offsets: what the springs target.
    private(set) var baseGeometry: ScreenGeometry {
        didSet { restStripRange = stripRange(in: baseGeometry, beside: []) }
    }
    /// The strip's range beside the docks at rest (`PaneArrival.stripClip`), computed when the geometry is
    /// (a row or a scroll area moves no dock and no clip edge), so a presentation with no dock growing in
    /// computes none.
    private(set) var restStripRange: CGRect?
    /// `baseGeometry` at the presented row and scroll area offsets (`shiftingRows`, `shiftingAreas`): what
    /// hit testing, drops, focus and the strip scroll read.
    var geometry: ScreenGeometry
    /// Where each pane and divider rests, and the CPU's spring toward that rest while it steps the motion. A
    /// motion the render server took rests here in the change's turn; its plan (``renderTracks``) holds where
    /// each pane sweeps until it lands. The springs stay until p03-rendering-022c removes CPU stepping.
    var panePlacement = LayoutFrames<PaneID>(), dividerPlacement = LayoutFrames<DividerHandleView.Kind>()
    /// The panes' and dividers' CPU springs (``panePlacement``), in place: a step mutates one entry, no copy.
    var paneFrames: [PaneID: AnimatedFrame] {
        get { panePlacement.springs }
        _modify { yield &panePlacement.springs }
    }
    var dividerFrames: [DividerHandleView.Kind: AnimatedFrame] {
        get { dividerPlacement.springs }
        _modify { yield &dividerPlacement.springs }
    }
    private(set) var dividerViews: [DividerHandleView.Kind: DividerHandleView] = [:]
    /// Panes growing in from a split's edge (`PaneArrival.split`), and the dock columns that change added.
    var arriving: Set<PaneID> = [], newDockColumns: Set<ColumnID> = []
    /// A zoom or unzoom: the pane that owns the motion, and the panes a zoom covers, unchanged under it.
    internal(set) var zoomMotion = PaneZoomMotion()
    var covered: Set<PaneID> { zoomMotion.covered }
    /// A close: the strip camera and each row column's move on the panes' (close) spring until
    /// everything rests, so a column whose strip move the camera cancels (the one right of a
    /// closed column, as the focus goes left) stays still instead of sliding in and out on two
    /// springs, and the shift after the last column or row closed is the close's own curve. A user
    /// scroll takes the camera back to the scroll spring.
    var scrollRidesFrames = false
    /// A close waits for the change turn to place its camera, then takes its first frame (`leadIfPending`).
    var leadsFrame = false
    /// This screen's render-server motion variants and the `motion.renderServer` switch
    /// (`ScreenContentView+Motion.swift`); the composition root passes the switch through the context.
    var motionBackends: MotionBackends<ScreenContentView>
    /// Change turns open on this screen (`beginMotionTurn`): a turn nested in another (a resize
    /// inside the root's) ends with the outer one.
    var motionTurnDepth = 0
    /// The presentation the open turn holds until its render-server kinds took their motions; nil
    /// while no turn holds one (always with the render server off).
    var heldPresentation: HeldPresentation?
    /// A split's or a close's panes spring to their new sizes: their terminals keep their grids
    /// until every pane landed (`LayoutViewContext.gridHoldScreens`, the PTY resizes once at rest).
    /// A press during the motion (rapid Cmd-D) keeps the hold, so the grids go once for the whole chain.
    var holdsGrids = false {
        didSet {
            guard holdsGrids != oldValue else { return }
            if holdsGrids { context.gridHoldScreens.insert(screenID) } else { context.gridHoldScreens.remove(screenID) }
        }
    }
    var motionState: ScreenPaneMotionState
    /// A divider released with this pointer velocity (pt/s along its axis): the next layout's
    /// spring starts from it (`SplitMotion.seed`).
    var releasedDivider: (kind: DividerHandleView.Kind, velocity: CGFloat, time: CFTimeInterval)?
    /// Column scroll rules and state (`ColumnScrollState.reduce`).
    var scrollState = ColumnScrollState()
    /// Each column whose rows overflow scrolls vertically with its own
    /// instance of the same rules (ScreenContentView+Rows.swift).
    var rowScrolls: [ColumnID: RowScroll] = [:]
    /// Each horizontal scroll area keeps its own instance of the same rules
    /// (ScreenContentView+ScrollAreas.swift).
    var areaScrolls: [SplitID: ScrollAreaScroll] = [:]
    /// Row and scroll area motion containers, and the scrollers the layout gives one now (`+Scrollers`).
    var scrollerContainers: [NestedScroller: ScrollerPanContainerView] = [:], wantedScrollers: Set<NestedScroller> = []
    /// Row and area offsets a remount gave before their scrolls were built (`restoreScroll`).
    var pendingScroll = LayoutScreenScroll()
    /// A row divider drag's heights, shown until the next layout arrives
    /// (gesture state; the model keeps no copy, rows.md Z1).
    var rowDragPreview: (column: ColumnID, heights: [RowHeight])?
    /// The strip camera as it shows: during a fling on the render server (`StripClipContainerView.fling`)
    /// the reducer's spring rests on the fling's target and this is where the strip is on the way. A
    /// write takes the camera back from the fling first (``takeCameraFromServer()``).
    var scroll: SpringValue {
        get { stripContainer.fling == nil ? scrollState.spring : flingCamera }
        set {
            takeCameraFromServer()
            scrollState.spring = newValue
        }
    }
    var isUserScrolling: Bool { scrollState.isGestureActive }
    var reportScrollOnSettle = false
    /// The focus the scroll last followed; a window resize re-syncs with it.
    var lastFocused: PaneID?
    var activeDrag: DividerDragState?
    /// A person's resize drag as the pane contents hear it (`ScreenContentView+ResizeGesture`).
    var resizeGesture = PaneResizeGesturePhase.idle
    /// The pane contents that heard the drag start; the end goes to them.
    var resizeGestureListeners: [PaneResizeGestureListener] = []
    /// Overlay docked columns' glass rims, keyed by column.
    var backdrops: [ColumnID: DockBackdropView] = [:]
    /// The strip scrollbar; created on first use.
    var scrollbar: StripScrollbarView?
    /// The offset the scrollbar last showed, and whether the next change
    /// came from scrolling (it flashes the scrollbar).
    var scrollbarOffset: CGFloat?
    var scrollbarFlash = false
    /// The canvas this screen shows, its camera and a pointer drag (ScreenContentView+Canvas).
    var canvasState = ScreenCanvasState()
    /// Layout motion the CPU step does not own has not ended yet: a user pan of this screen stepped the
    /// layout (`applyPresentation`), or render-server springs run (``renderSpringsInFlight``).
    var userMotionActive = false
    /// Render-server spring calls of this screen's panes and dividers that have not landed
    /// (`ScreenContentView+RenderMotion.swift`).
    var renderSpringsInFlight = 0
    /// A close on the render server that has not landed and still owns the camera (`springCloseOnRenderServer`).
    var renderClose: RenderClose?
    /// The render-server springs still carrying panes and dividers, what a later change starts from.
    var renderTracks = RenderTracks()
    /// A strip pan event showed in the current display frame (``presentPan()``); the frame's tick
    /// clears it (``displayFrameBegan()``).
    var panPresentedInFrame = false
    /// Strip pan events reduced but not shown yet: the next frame tick shows them in one presentation.
    var panPresentationPending = false
    /// The strip's dividers sit in the strip container with its hosts (the last `ensureStacking`), so a
    /// pan on the container moves them (`ScreenContentView+StripPan.swift`).
    var stripDividersInContainer = false
    /// While the container carries the pan, the strip offset its views are laid out at; nil when
    /// they are laid out at the camera.
    var panBase: CGFloat?
    /// The strip offset the last layout pass placed the hosts and dividers at (``applyPresentation(force:)``).
    var laidOutStripOffset: CGFloat = 0
    /// The strip shift the last visibility pass saw and how far a pan can go from it before a pane
    /// enters or leaves (``recordVisibilitySpan(_:)``).
    var visibilitySpan: (shift: CGFloat, span: PanVisibilitySpan)?
    /// Pane clips computed, cumulative (PaneMotionWorkTests): a spring or a pan beside docks computes none.
    var stripClipsComputed = 0
    /// Strip ranges computed (`PaneArrival.stripClip`), cumulative (DockArrivalRenderMotionTests): a dock on
    /// the render server computes them at plan apply only.
    var stripRangesComputed = 0
    /// Moves on with any change to the hosts' frames, alphas, clips or order (`PaneHostView.pageCovers`).
    var coverVersion = 0
    /// The strip's panes sit in this view, which clips them to the strip's range by its bounds
    /// (`StripClipContainerView`); the docks stack above it.
    let stripContainer = StripClipContainerView(frame: .zero)
    /// The strip panes' rings and dims while the strip pans on its container: the root puts it in the
    /// overlay plane, and it takes the container's translation (`StripChromePlane`).
    let stripChrome = StripChromePlane(frame: .zero)
    init(screenID: ScreenID, layout: ScreenLayout, context: LayoutViewContext,
         paneMotionVariant: @escaping () -> PaneMotionVariant = { LayoutTunables.paneMotionVariant.value }) {
        self.screenID = screenID
        self.layout = layout
        self.context = context
        self.motionState = ScreenPaneMotionState(provider: paneMotionVariant)
        self.motionBackends = MotionBackends(ScreenContentView.renderServerMotions, renderServer: context.rendersMotionOnServer)
        self.baseGeometry = ScreenGeometry.compute(layout, viewport: .zero, style: context.style)
        self.geometry = baseGeometry
        self.restStripRange = PaneArrival.stripClip(baseGeometry, docks: [])
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(stripContainer)
        stripContainer.companion = stripChrome.layer
        stripContainer.onShowsMovedChange = { [weak self] in self?.context.stripMovedDidChange() }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        // A hidden screen (another of the workspace's screens shows) lays out once, when it shows:
        // each live-resize tick re-ran its full geometry, pane and divider reconcile.
        if isHidden { needsReconcileOnShow = true } else { reconcileAndScroll(keepsMotion: hasMotion && window?.inLiveResize != true) }
    }

    /// Resized while hidden: reconcile when it shows.
    private(set) var needsReconcileOnShow = false

    override func viewDidUnhide() { // visibility-walk-allow: the screen's own hidden flag (another screen of its workspace shows) has no node; the resize it missed reconciles once on show, as deferUntilVisible would
        super.viewDidUnhide()
        reconcileIfDeferred()
    }

    /// Runs the reconcile a resize while hidden left for later (a reader that needs the screen's
    /// frames at its current size before it shows: a canvas seed).
    func reconcileIfDeferred() {
        guard needsReconcileOnShow else { return }
        needsReconcileOnShow = false
        reconcileAndScroll()
    }

    /// The backing scale the frames were last computed at (`reconcile`), nil before the first pass.
    private(set) var reconciledScale: CGFloat?
    /// `applyCamera` is setting the bounds (the canvas camera).
    var isApplyingCamera = false
    /// Reconcile passes, cumulative (ScreenBackingChangeTests: a bounds change is not a backing change).
    private(set) var reconcilePasses = 0

    /// Only a real scale change (the window moved to a display of another scale) lays out again.
    /// AppKit also calls this inside `setBoundsSize`, which the canvas camera sets (`applyCamera`):
    /// reconciling there set the bounds again and recursed until the stack overflowed (Crash D, #24998).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard !isApplyingCamera, window != nil, reconciledScale != scale else { return }
        reconcileAndScroll()
    }

    /// Ends pane and divider motion where it was going before a hidden workspace's clock stops.
    /// A pane spring left mid-flight could park its pane off screen. Column and row camera
    /// springs may resume when the workspace shows (Lucas 2026-10-19).
    func settleMotion() {
        defer { if resizeGesture == .landing { finishResizeGesture() } }
        finishPanFling()
        guard hasMotion else { return }
        reconcileAndScroll()
    }

    /// A window resize: frames snap (or, `keepsMotion`, a running spring retargets), and the scroll keeps the
    /// focused column in place on screen, then fits it (L7). A render-server camera move comes back first (its
    /// zoom pivots on the old viewport center); the turn's end hands it over again at the new size.
    fileprivate func reconcileAndScroll(keepsMotion: Bool = false) {
        takeCanvasCameraBack()
        motionTurn {
            reconcile(animated: keepsMotion)
            return syncScroll(focused: lastFocused, source: .programmatic, mode: context.model.centerFocusedColumn, animated: keepsMotion)
        }
    }

    // MARK: Model updates

    /// Applies a new layout. Returns true if springs need frames.
    ///
    /// A split or a new dock column grows in from its edge (`PaneArrival`, cx-f6i7;
    /// a dock moves the strip's origin, so strip frames start where they show), and the panes
    /// left by a close or a move away spring to their places (`PaneArrival.departing`); a zoom and
    /// an unzoom move as `PaneZoomMotion` says (the zooming pane covers the others, which stay still).
    /// Every moving pane lays out live at its spring rect on every frame (`applyPresentation`).
    /// Other structural changes snap.
    /// Ratio and width changes (equalize, width presets, another client's
    /// divider drag) keep their spring. The strip scroll (including the
    /// spring back after the last column closes) is `syncScroll`'s.
    @discardableResult
    func update(layout: ScreenLayout, zoomed: Bool = false, canvas: CanvasScreen? = nil, animated: Bool) -> Bool {
        // Into or out of a canvas, frames change coordinate space (the camera is the bounds): they snap.
        let animated = updateCanvas(canvas, animated: animated) && animated
        let structural = !self.layout.hasSameStructure(as: layout)
        let unzooming = self.zoomed && !zoomed
        let zooming = !self.zoomed && zoomed
        self.layout = layout
        self.zoomed = zoomed
        // The release's intent is in this layout (or was refused).
        if activeDrag == nil { rowDragPreview = nil }
        let moving = reconcile(animated: animated, structural: structural, unzooming: unzooming, zooming: zooming)
        return moving || canvasState.camera.isMoving
    }

    @discardableResult
    func reconcile(animated: Bool, structural: Bool = false, unzooming: Bool = false, zooming: Bool = false) -> Bool {
        // A layout change takes the camera, rows and scroll areas from flings on the render server: the CPU carries them on.
        takeCameraFromServer()
        takeScrollersFromServer()
        let shown = rowDragPreview.map { layout.settingRowHeights($0.heights, for: $0.column) } ?? layout
        let before = geometry
        // A new structure starts from what shows, render-server springs included (`takeRenderSpringsBack`).
        if structural { takeRenderSpringsBack() }
        // One style read per pass: it is resolved from the settings.
        let style = context.style
        reconcilePasses += 1
        applyCamera()
        reconciledScale = scale
        baseGeometry = canvasGeometry ?? ScreenGeometry.compute(shown, viewport: bounds.size, style: style, scale: scale)
        geometry = baseGeometry.shiftingAreas(areaOffsets).shiftingRows(rowOffsets)
        reconcileScrollerContainers() // before `hostParent` puts a new host in one
        let animate = animated && !context.reduceMotion && bounds.width > 0
        // `ui.paneAnimations` (default on): a split, a close and a released divider spring only with it on.
        let splits = animate && context.animatesPaneLayout
        var arrivals = splits && structural && !unzooming
            ? PaneArrival.split(panePlacement.rests, from: before, to: baseGeometry, offset: scroll.value) : [:]
        // A pane that hands what it shows to the pane this change adds (`LayoutModel.handOffContent`): the
        // added pane shows in place and the giver slides in (`PaneArrival.handoff`). A pane added on the
        // giver's screen spends it.
        var handoff: (pane: PaneID, slide: CGRect)?
        if structural, let giver = context.model.pendingContentHandoff, before.panes[giver] != nil,
           baseGeometry.panes.keys.contains(where: { before.panes[$0] == nil }) {
            context.model.contentHandoff = nil
            if let played = PaneArrival.handoff(arrivals, giver: giver, from: before, to: baseGeometry, offset: scroll.value) {
                (arrivals, handoff) = (played.arrivals, (giver, played.slide))
            }
        }
        let departing = (zooming ? animate : splits) && structural && arrivals.isEmpty
            && PaneArrival.departing(paneFrames.keys, to: baseGeometry.panes.keys)
        // An unzoom: the other panes come back in place under the zoomed one, which springs back to its slot.
        let returning = animate && structural && unzooming
        // A zoom: the zoomed pane covers the other panes, which stay as they are under it (`PaneZoomMotion`).
        let covering = animate && structural && zooming
        if structural { zoomMotion.begin(covering ? baseGeometry.panes.keys.first : returning ? paneFrames.keys.first { baseGeometry.panes[$0] != nil } : nil, in: baseGeometry, variant: motionState.current) }
        // A split still springing when the next structural update lands (the daemon's echo of the
        // split moves the tab into the new pane ~75 ms in) keeps springing from where it shows,
        // with its velocity, instead of snapping to the end (hq-1d: Cmd-D measured 4 frames).
        let wasMoving = hasMotion, targetsBefore = (panes: panePlacement.rests, dividers: dividerPlacement.rests) // M1, M4
        let inFlight = splits && structural && arrivals.isEmpty && !departing
            && paneFrames.values.contains { $0.rect != $0.targetRect }
        motionState.retarget(structural: structural, inFlight: inFlight, departing: departing, zooming: zooming, splitting: !arrivals.isEmpty, hasFrames: paneFrames.values.contains { $0.rect != $0.targetRect })
        // An animated width or ratio change (a preset, an equalize) is carried too: its camera may re-anchor (M8).
        let carried = !arrivals.isEmpty || departing || returning || (animate && !structural)
        (panePlacement.carried, dividerPlacement.carried) = ([:], [:])
        // A release seeds only the layout it made (`releasedDivider` from this gesture, not a stale one).
        if let released = releasedDivider, CACurrentMediaTime() - released.time > 0.5 { releasedDivider = nil }
        let animateFrames = animate && (!structural || carried || inFlight) && (releasedDivider == nil || splits)
        if structural, !inFlight { (arriving, newDockColumns) = (Set(arrivals.keys), PaneArrival.newDocks(arrivals, from: before, to: baseGeometry)) }

        // Panes. A new pane's sliver rides its neighbour's edge as it showed before this change.
        let pass = LayoutFramePass(before: before, after: baseGeometry, arrivals: arrivals, handoff: handoff, carried: carried,
                                   animated: animateFrames, keepsRunning: context.model.isGestureActive && !context.reduceMotion,
                                   offset: scroll.value, shownBefore: arrivals.isEmpty ? [:] : paneFrames)
        for (pane, target) in baseGeometry.panes {
            if paneFrames[pane] == nil {
                let host = context.host(for: pane)
                // Under the zooming pane and the dividers: `reconcileDock` ranks it (`ensureStacking`).
                if !holds(host) { move(host, to: hostParent(for: pane)) }
                zoomMotion.returning(pane)
            }
            panePlacement.place(pane, at: target, pass: pass)
            if let handoff, handoff.pane == pane {
                // PaneHostView must distinguish this from an ordinary moving shrink: both have a
                // nonzero rest offset, but only a handoff's first frame is already at its target size.
                context.hosts[pane]?.isContentHandoff = true
            }
            context.hosts[pane]?.applyShape(padding: style.panePadding, cornerRadius: style.paneCornerRadius, wholeCard: style.floatingPanes)
        }
        for pane in paneFrames.keys where baseGeometry.panes[pane] == nil {
            let frame = paneFrames.removeValue(forKey: pane)
            if covering, let host = context.hosts[pane], holds(host), frame != nil {
                zoomMotion.leave(pane)
                continue
            }
            // A pane that moved to another screen belongs to that screen now.
            if !context.livePanes.contains(pane) { context.release(pane) }
        }

        // Dividers and column edges.
        var targets: [DividerHandleView.Kind: (rect: CGRect, axis: SplitAxis)] = [:]
        for divider in baseGeometry.dividers { targets[.split(divider.id)] = (divider.hitFrame, divider.axis) }
        for edge in baseGeometry.columnEdges { targets[.columnEdge(edge.column)] = (edge.hitFrame, edge.axis) }
        // Row heights are resizable only where the daemon serves rows-v1.
        if context.model.acceptsRowOps {
            for edge in baseGeometry.rowEdges { targets[.rowEdge(edge.column, edge.upper)] = (edge.hitFrame, .vertical) }
        }
        // A column edge whose column changed id in place (a New Column stand-in's handoff) keeps its spring.
        var renamedEdges = dividerPlacement.renamedEdges(beside: targets)
        for (kind, target) in targets {
            let view: DividerHandleView
            if let existing = dividerViews[kind] {
                view = existing
                view.setAxis(target.axis)
            } else {
                view = DividerHandleView(kind: kind, axis: target.axis)
                view.onDrag = { [weak self] event in self?.handleDrag(kind: kind, event: event) }
                followDragInput(view)
                view.onPointerChange = { [weak self] event in self?.refreshDividerHover(at: event) }
                // Ranked by `reconcileDock` (`ensureStacking`).
                dividerParent(for: kind, inContainer: dividersInStripContainer).addSubview(view)
                dividerViews[kind] = view
            }
            view.lineThickness = style.dividerThickness
            view.showsIdleLine = kind.usesRowSeparator ? style.showsRowSeparator : style.showsDividerLine
            view.showsActiveLine = style.showsDividerFeedback
            dividerPlacement.place(kind, at: target, scrolls: scrolls(kind), pass: pass, panes: paneFrames, renamed: &renamedEdges)
        }
        for kind in dividerViews.keys where targets[kind] == nil {
            // The handle under a drag goes away: its mouse-up never comes.
            if activeDrag?.kind == kind { endDrag() }
            dividerViews.removeValue(forKey: kind)?.removeFromSuperview()
            dividerFrames[kind] = nil
        }

        if let released = releasedDivider {
            releasedDivider = nil
            if animateFrames, splits, let divider = dividerFrames[released.kind] {
                SplitMotion.seed(velocity: released.velocity, along: dividerViews[released.kind]?.axis ?? .horizontal, divider: divider,
                                 panes: &paneFrames, dividers: &dividerFrames, moved: Set(paneFrames.keys.filter { targetsBefore.panes[$0] != paneFrames[$0]?.targetRect }),
                                 movedDividers: Set(dividerFrames.keys.filter { targetsBefore.dividers[$0] != dividerFrames[$0]?.targetRect }))
            }
        }

        if structural { scrollRidesFrames = departing && animateFrames && !covering }
        // A close's neighbours start covering the closed pane's space in the frame it leaves:
        // no frame shows the hole before they move (`leadIfPending`, at the end of the change turn).
        leadsFrame = departing && animateFrames && !covering && !wasMoving
        // A split's or a close's terminals no longer keep their grids until the spring lands (Lawrence
        // 2026-10-23: they resize at the start): each resized pane hears its final size in the step that
        // starts or retargets its spring (`PaneHostView.announceRest`, `PaneMotionTargeting`).
        reconcileDock()
        reconcileCanvasStacking()
        // The scroll follows in `syncScroll`, which the root calls with the focus after every update.
        // Only a structural change re-places everything: a ratio, width or row-height change (every divider
        // drag step, an equalize) moves only the panes whose frames changed, and every per-pane input (frame,
        // alpha, clip range, covers, divider clips) is compared in the pass (`applyPresentation`).
        applyPresentation(force: structural)
        let moving = animate && hasMotion
        if !moving { releaseCovered() }
        if !(moving && holdsGrids) { holdsGrids = false }
        return moving
    }

    /// Lets go of the panes a zoom covered once it landed (every one with `all`).
    func releaseCovered(all: Bool = false) {
        for pane in zoomMotion.settled(all: all) where paneFrames[pane] == nil && !context.livePanes.contains(pane) {
            context.release(pane)
            coverVersion &+= 1
        }
    }

    /// The panes and strip dividers a structural change carried start where they showed before it, now that the
    /// camera is where the new layout puts it: a zoom resets the scroll, an unzoom snaps it to
    /// the focused column, and a close left of the focus moves the anchor along at once.
    func settleCarried() {
        guard !panePlacement.carried.isEmpty || !dividerPlacement.carried.isEmpty else { return }
        let shift = stripShift
        panePlacement.settleCarried { [geometry] pane in geometry.scrolls(pane: pane) ? shift : 0 }
        dividerPlacement.settleCarried { _ in shift }
    }

    /// A row divider release's preview waits for the layout that carries
    /// it: the next model sync reconciles this screen even when its layout
    /// did not change (the daemon refused the heights).
    var holdsRowDragPreview: Bool { rowDragPreview != nil && activeDrag == nil }

    /// Releases every hosted pane that is not live elsewhere (screen removed).
    func tearDown() {
        // A drag on a screen that goes away gets no release either.
        endDrag()
        finishResizeGesture()
        holdsGrids = false
        for pane in paneFrames.keys where !context.livePanes.contains(pane) {
            context.release(pane)
        }
        paneFrames.removeAll()
        releaseCovered(all: true)
    }
}
