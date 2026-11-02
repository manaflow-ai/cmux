import AppKit
import CmuxNextDesign
/// Renders one screen: a split tree, or a horizontally scrolling strip of
/// columns. Pane and divider frames are springs in content space; the
/// displayed frame subtracts the scroll offset.
final class ScreenContentView: NSView {
    let screenID: ScreenID
    let context: LayoutViewContext
    private(set) var layout: ScreenLayout
    /// The layout is one zoomed pane (`LayoutScreen.zoomed`).
    private(set) var zoomed = false
    /// Where the panes a structural change carries showed (view x), set again
    /// once `syncScroll` has moved the camera for the new layout (`settleCarried`).
    var carriedShown: [PaneID: CGFloat] = [:]
    /// The same for the strip's dividers and column edges.
    var carriedDividers: [DividerHandleView.Kind: CGFloat] = [:]
    /// Frames before the rows' vertical offsets: what the springs target.
    private(set) var baseGeometry: ScreenGeometry
    /// `baseGeometry` at the presented row and scroll area offsets (`shiftingRows`, `shiftingAreas`): what
    /// hit testing, drops, focus and the strip scroll read.
    var geometry: ScreenGeometry
    internal(set) var paneFrames: [PaneID: AnimatedFrame] = [:]
    private(set) var dividerViews: [DividerHandleView.Kind: DividerHandleView] = [:]
    internal(set) var dividerFrames: [DividerHandleView.Kind: AnimatedFrame] = [:]
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
    /// A close waits for `syncScroll` to place its camera, then takes its first frame (`leadIfPending`).
    var leadsFrame = false
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
    /// A row divider drag's heights, shown until the next layout arrives
    /// (gesture state; the model keeps no copy, rows.md Z1).
    var rowDragPreview: (column: ColumnID, heights: [RowHeight])?
    var scroll: SpringValue {
        get { scrollState.spring }
        set { scrollState.spring = newValue }
    }
    var isUserScrolling: Bool { scrollState.isGestureActive }
    var reportScrollOnSettle = false
    /// The focus the scroll last followed; a window resize re-syncs with it.
    var lastFocused: PaneID?
    var activeDrag: DividerDragState?
    /// Column widths before a create, for the R3b check (``ColumnWidthLedger``); recorded in debug builds only.
    var columnWidths = ColumnWidthLedger()
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
    /// A user pan of this screen stepped the layout and has not ended yet (`applyPresentation`).
    var userMotionActive = false
    /// A strip pan event showed in the current display frame (``presentPan()``); the frame's tick
    /// clears it (``displayFrameBegan()``).
    var panPresentedInFrame = false
    /// Strip pan events reduced but not shown yet: the next frame tick shows them in one presentation.
    var panPresentationPending = false
    /// Frame ticks the pan still keeps after its last event (``displayFrameBegan()``).
    var panTicksLeft = 0
    /// Pane strip clips computed and presentation passes run, cumulative (PaneMotionWorkTests: per frame the clips
    /// are the panes that moved or whose covers changed; `LayoutWorkProbe`), and a structural change's next pass re-places all.
    var stripClipsComputed = 0, presentationPasses = 0, forcesPresentation = false
    init(screenID: ScreenID, layout: ScreenLayout, context: LayoutViewContext,
         paneMotionVariant: @escaping () -> PaneMotionVariant = { LayoutTunables.paneMotionVariant.value }) {
        self.screenID = screenID
        self.layout = layout
        self.context = context
        self.motionState = ScreenPaneMotionState(provider: paneMotionVariant)
        self.baseGeometry = ScreenGeometry.compute(layout, viewport: .zero, style: context.style)
        self.geometry = baseGeometry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
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

    override func viewDidUnhide() {
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
        guard hasMotion else { return }
        reconcileAndScroll()
    }

    /// A window resize: frames snap (or, `keepsMotion`, a running spring retargets), and the scroll keeps the
    /// focused column in place on screen, then fits it (L7).
    fileprivate func reconcileAndScroll(keepsMotion: Bool = false) {
        reconcile(animated: keepsMotion, presents: false)
        syncScroll(focused: lastFocused, source: .programmatic, mode: context.model.centerFocusedColumn, animated: keepsMotion)
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
        #if DEBUG
        let shapeBefore = structural && !isHidden && canvas == nil && !self.zoomed && !zoomed ? restColumns : nil
        #endif
        self.layout = layout
        self.zoomed = zoomed
        // The release's intent is in this layout (or was refused).
        if activeDrag == nil { rowDragPreview = nil }
        let moving = reconcile(animated: animated, structural: structural, unzooming: unzooming, zooming: zooming, presents: false)
        #if DEBUG
        if let shapeBefore { columnWidths.noteChange(from: shapeBefore, to: restColumns, viewportWidth: bounds.width) }
        #endif
        return moving || canvasState.camera.isMoving
    }

    @discardableResult
    func reconcile(animated: Bool, structural: Bool = false, unzooming: Bool = false, zooming: Bool = false, presents: Bool = true) -> Bool {
        let shown = rowDragPreview.map { layout.settingRowHeights($0.heights, for: $0.column) } ?? layout
        let before = geometry
        // One style read per pass: it is resolved from the settings.
        let style = context.style
        reconcilePasses += 1
        applyCamera()
        reconciledScale = scale
        baseGeometry = canvasGeometry ?? ScreenGeometry.compute(shown, viewport: bounds.size, style: style, scale: scale)
        geometry = baseGeometry.shiftingAreas(areaOffsets).shiftingRows(rowOffsets)
        let animate = animated && !context.reduceMotion && bounds.width > 0
        // `ui.paneAnimations` (default on): a split, a close and a released divider spring only with it on.
        let splits = animate && context.animatesPaneLayout
        var arrivals = splits && structural && !unzooming
            ? PaneArrival.split(paneFrames.mapValues(\.targetRect), from: before, to: baseGeometry, offset: scroll.value) : [:]
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
        let wasMoving = hasMotion, targetsBefore = (panes: paneFrames.mapValues(\.targetRect), dividers: dividerFrames.mapValues(\.targetRect)) // M1, M4
        let inFlight = splits && structural && arrivals.isEmpty && !departing
            && paneFrames.values.contains { $0.rect != $0.targetRect }
        motionState.retarget(structural: structural, inFlight: inFlight, departing: departing, zooming: zooming, splitting: !arrivals.isEmpty, hasFrames: paneFrames.values.contains { $0.rect != $0.targetRect })
        // An animated width or ratio change (a preset, an equalize) is carried too: its camera may re-anchor (M8).
        let carried = !arrivals.isEmpty || departing || returning || (animate && !structural)
        // Strip springs run in strip coordinates and fixed ones in the view's: a moved strip origin (a dock
        // that came or went) or a pane changing sides (a zoom shows its pane fixed) keeps it where it showed.
        let offset = scroll.value
        func shift(_ geometry: ScreenGeometry, _ pane: PaneID) -> CGFloat { geometry.scrolls(pane: pane) ? geometry.viewShift(offset: offset) : 0 }
        let drift = carried ? before.viewShift(offset: offset) - baseGeometry.viewShift(offset: offset) : 0
        (carriedShown, carriedDividers) = ([:], [:])
        // A release seeds only the layout it made (`releasedDivider` from this gesture, not a stale one).
        if let released = releasedDivider, CACurrentMediaTime() - released.time > 0.5 { releasedDivider = nil }
        let animateFrames = animate && (!structural || carried || inFlight) && (releasedDivider == nil || splits)
        if structural, !inFlight { (arriving, newDockColumns) = (Set(arrivals.keys), PaneArrival.newDocks(arrivals, from: before, to: baseGeometry)) }

        // Panes. A new pane's sliver rides its neighbour's edge as it showed before this change.
        let shownBefore = arrivals.isEmpty ? [:] : paneFrames
        for (pane, target) in baseGeometry.panes {
            if var existing = paneFrames[pane] {
                if carried {
                    carriedShown[pane] = existing.x.value + shift(before, pane)
                    existing.x.value += shift(before, pane) - shift(baseGeometry, pane)
                }
                if let handoff, handoff.pane == pane {
                    // At its new size past the screen edge, from where it slides in.
                    existing = AnimatedFrame(handoff.slide.offsetBy(dx: -shift(baseGeometry, pane), dy: 0))
                    carriedShown[pane] = handoff.slide.minX
                }
                place(&existing, at: target, animated: animateFrames)
                paneFrames[pane] = existing
            } else {
                let host = context.host(for: pane)
                if host.superview !== self {
                    // Under the zooming pane and the dividers: `reconcileDock` ranks it (`ensureStacking`).
                    addSubview(host, positioned: .below, relativeTo: firstDividerView)
                }
                // Opaque from its first frame: an arriving pane grows in from its edge, never fades.
                var frame = AnimatedFrame(arrivals[pane]?.seed ?? target)
                if arrivals[pane] != nil { SplitMotion.ride(&frame, panes: shownBefore, skipping: Set(arrivals.keys)) }
                zoomMotion.returning(pane)
                frame.setTarget(target, alpha: 1)
                paneFrames[pane] = frame
            }
            if let handoff, handoff.pane == pane {
                // PaneHostView must distinguish this from an ordinary moving shrink: both have a
                // nonzero rest offset, but only a handoff's first frame is already at its target size.
                context.hosts[pane]?.isContentHandoff = true
            }
            context.hosts[pane]?.applyShape(padding: style.panePadding, cornerRadius: style.paneCornerRadius, wholeCard: style.floatingPanes)
        }
        for pane in paneFrames.keys where baseGeometry.panes[pane] == nil {
            let frame = paneFrames.removeValue(forKey: pane)
            if covering, context.hosts[pane]?.superview === self, frame != nil {
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
        var renamedEdges: [AnimatedFrame] = dividerFrames.compactMap { kind, frame in
            if case .columnEdge = kind, targets[kind] == nil { return frame }
            return nil
        }
        for (kind, target) in targets {
            let view: DividerHandleView
            if let existing = dividerViews[kind] {
                view = existing
                view.setAxis(target.axis)
            } else {
                view = DividerHandleView(kind: kind, axis: target.axis)
                view.onDrag = { [weak self] event in self?.handleDrag(kind: kind, event: event) }
                view.onPointerChange = { [weak self] in self?.context.invalidateHoverTopmost(); self?.refreshDividerHover() }
                addSubview(view)
                dividerViews[kind] = view
            }
            view.lineThickness = style.dividerThickness
            view.showsIdleLine = kind.usesRowSeparator ? style.showsRowSeparator : style.showsDividerLine
            view.showsActiveLine = style.showsDividerFeedback
            if var frame = dividerFrames[kind] {
                if scrolls(kind) {
                    if carried { carriedDividers[kind] = frame.x.value + before.viewShift(offset: offset) }
                    frame.x.value += drift
                }
                place(&frame, at: target.rect, animated: animateFrames)
                dividerFrames[kind] = frame
            } else if case .columnEdge = kind,
                      let index = renamedEdges.firstIndex(where: { abs($0.targetRect.minX - target.rect.minX) < 0.5 && abs($0.targetRect.width - target.rect.width) < 0.5 }) {
                var frame = renamedEdges.remove(at: index)
                place(&frame, at: target.rect, animated: animateFrames)
                dividerFrames[kind] = frame
            } else {
                // A split's new divider starts on the edge of the pane beside it, where that edge shows now
                // (an even split may put it past the new pane, on the next pane's edge); an unzoom's are
                // there at once, under the zoomed pane springing back (it ranks above them).
                // A handoff's added pane is in place already and its giver comes from the screen edge: its
                // dividers are in place too.
                let start = arrivals.isEmpty || handoff != nil ? nil : SplitMotion.startShift(of: target.rect, axis: target.axis, panes: paneFrames,
                                                                                              skipping: Set(arrivals.keys))
                let edge = arrivals.isEmpty || handoff != nil ? .zero : start?.shift ?? arrivals.values.first?.edgeOffset ?? .zero
                var frame = AnimatedFrame(target.rect.offsetBy(dx: edge.dx, dy: edge.dy), alpha: 1)
                frame.setTarget(target.rect, alpha: 1)
                // It moves with that edge from its first frame (a split landing mid-motion), and across its axis it
                // shows where that pane shows (a pane still moving sideways).
                if let start {
                    if target.axis == .horizontal {
                        frame.x.velocity = start.velocity
                        SplitMotion.follow(&frame.y, &frame.height, beside: start.beside.y, start.beside.height)
                    } else {
                        frame.y.velocity = start.velocity
                        SplitMotion.follow(&frame.x, &frame.width, beside: start.beside.x, start.beside.width)
                    }
                }
                dividerFrames[kind] = frame
            }
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
        // no frame shows the hole before they move (`leadIfPending`, after `syncScroll`).
        leadsFrame = departing && animateFrames && !covering && !wasMoving
        // A split's or a close's terminals no longer keep their grids until the spring lands (Lawrence
        // 2026-10-23: they resize at the start): each resized pane hears its final size in the step that
        // starts or retargets its spring (`PaneHostView.announceRest`, `PaneMotionTargeting`).
        reconcileDock()
        reconcileCanvasStacking()
        // The scroll follows in `syncScroll`, which the root calls with the focus after every update, and presents.
        // Only a structural change re-places everything: a ratio, width or row-height change (every divider
        // drag step, an equalize) moves only the panes whose frames changed, and every per-pane input (frame,
        // alpha, clip range, covers, divider clips) is compared in the pass (`applyPresentation`).
        if structural { forcesPresentation = true }
        if presents { applyPresentation() }
        let moving = animate && hasMotion
        if !(moving && holdsGrids) { holdsGrids = false }
        return moving
    }

    /// Lets go of the panes a zoom covered once it landed (every one with `all`).
    func releaseCovered(all: Bool = false) {
        for pane in zoomMotion.settled(all: all) where paneFrames[pane] == nil && !context.livePanes.contains(pane) {
            context.release(pane)
        }
    }

    /// The panes and strip dividers a structural change carried start where they showed before it, now that the
    /// camera is where the new layout puts it: a zoom resets the scroll, an unzoom snaps it to
    /// the focused column, and a close left of the focus moves the anchor along at once.
    func settleCarried() {
        guard !carriedShown.isEmpty || !carriedDividers.isEmpty else { return }
        let shift = stripShift
        for (pane, shown) in carriedShown {
            guard var frame = paneFrames[pane] else { continue }
            frame.x.value = shown - (geometry.scrolls(pane: pane) ? shift : 0)
            paneFrames[pane] = frame
        }
        for (kind, shown) in carriedDividers {
            guard var frame = dividerFrames[kind] else { continue }
            frame.x.value = shown - shift
            dividerFrames[kind] = frame
        }
        (carriedShown, carriedDividers) = ([:], [:])
    }

    fileprivate var firstDividerView: NSView? {
        subviews.first { $0 is DividerHandleView }
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
