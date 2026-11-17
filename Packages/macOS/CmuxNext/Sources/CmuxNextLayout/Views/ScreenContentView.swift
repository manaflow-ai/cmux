import AppKit
import CmuxNextDesign
/// Renders one screen: a split tree, or a horizontally scrolling strip of columns. Pane and divider frames are springs
/// in content space (a ratio or width change moves them; a structural change puts each at its place in one frame); the
/// displayed frame subtracts the scroll offset.
final class ScreenContentView: NSView {
    let screenID: ScreenID
    let context: LayoutViewContext
    private(set) var layout: ScreenLayout { didSet { layoutRevision &+= 1 } }
    /// Bumped on every layout change: what the tab-drop answers (`DropAnswerMemo`) were worked out for.
    private(set) var layoutRevision: UInt64 = 0
    /// The layout is one zoomed pane (`LayoutScreen.zoomed`).
    private(set) var zoomed = false
    /// Where the panes an animated width or ratio change carries showed (view x), set again
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
    /// The screen's splits whose divider draws no line (``LayoutScreen/hiddenDividers``); set by the root before each update.
    var hiddenDividers: Set<SplitID> = [] {
        didSet { if hiddenDividers != oldValue { hiddenDividersDidChange(from: oldValue) } }
    }
    /// The hover and resize cursor of those handles from one tracking area (`ScreenDividerPointer`).
    private(set) lazy var dividerPointer = ScreenDividerPointer(screen: self)
    internal(set) var dividerFrames: [DividerHandleView.Kind: AnimatedFrame] = [:]
    /// A keyboard resize press moves this screen (`LayoutRootView.keyboardResizeWillChange`): until its spring lands,
    /// every pane is on the key hold (``PaneHostView``): content with a hold area follows its pane in every frame.
    var holdsContentForKeyResize = false { didSet { if oldValue, !holdsContentForKeyResize { releasePaneFrameNoticesIfSettled() } } }
    /// The layout change that `update` just applied is structural, and its scroll sync has not run yet (`syncScroll`
    /// follows every update): that sync puts each camera at its place with the change, in the same frame.
    var scrollSyncIsStructural = false
    /// The terminals of this screen keep their grids until its panes land (`LayoutViewContext.gridHoldScreens`).
    /// Nothing sets it now: a split or a close shows in one frame, and its terminals take their grids with that
    /// frame. It stays, with its observers, until its own removal.
    var holdsGrids = false {
        didSet {
            guard holdsGrids != oldValue else { return }
            if holdsGrids { context.gridHoldScreens.insert(screenID) } else { context.gridHoldScreens.remove(screenID) }
        }
    }
    /// A divider released with this pointer velocity (pt/s along its axis): the next layout's
    /// spring starts from it (`SplitMotion.seed`).
    var releasedDivider: (kind: DividerHandleView.Kind, velocity: CGFloat, time: CFTimeInterval, sharedEdges: Bool)?
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
    /// The pane views a resize drag or a key resize's spring moves post no frame notice until it ends
    /// (``FrameNoticeHold``): no titlebar drag-shape walk in each of its frames' commits.
    let paneFrameNotices = FrameNoticeHold()
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
    /// What the screen shows once per display frame: a strip pan's events, a presentation the frame's input held.
    var frameInput = ScreenFrameInput()
    /// Pane strip clips computed and presentation passes run, cumulative (PaneMotionWorkTests: per frame the clips
    /// are the panes that moved or whose covers changed; `LayoutWorkProbe`), and a structural change's next pass re-places all.
    var stripClipsComputed = 0, presentationPasses = 0, forcesPresentation = false
    /// Panes that showed their ground because a surface of theirs was not ready when its layout change showed
    /// (`ScreenContentView+SnapFrame`), cumulative.
    var lateSurfaceCommits = 0
    /// Whole-screen geometry computes a tab drop's hit test made (room check and edge preview; HOT PATH AUDIT drag-frame).
    var dropGeometryComputes = 0
    /// The room checks and edge previews of this layout, viewport and style: a pointer move inside one zone computes none.
    var dropAnswers = DropAnswerMemo()
    init(screenID: ScreenID, layout: ScreenLayout, context: LayoutViewContext) {
        self.screenID = screenID
        self.layout = layout
        self.context = context
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
        // Never laid out: its first pass (the root's sync, `update(layout:)`) lays out at this size, once.
        guard changed, reconciledScale != nil else { return }
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
    /// A new screen joining its window is not one: it has no frames yet, and the root's sync lays it out next, at its
    /// size (SWITCH STALL 3: that join reconciled every new screen at viewport zero, its pane hosts made and placed at
    /// zero rects, then twice more in the same turn).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard !isApplyingCamera, window != nil, let reconciledScale, reconciledScale != scale else { return }
        reconcileAndScroll()
    }

    /// Ends pane and divider motion where it was going before a hidden workspace's clock stops.
    /// A pane spring left mid-flight could park its pane off screen. Column and row camera
    /// springs may resume when the workspace shows (Lucas 2026-10-19).
    func settleMotion() {
        // Landed at once (window out of sight, Reduce Motion turned on): the key-resize hold ends with the motion.
        defer { holdsContentForKeyResize = false }
        defer { releasePaneFrameNoticesIfSettled() }
        defer { if resizeGesture == .landing { finishResizeGesture() } }
        presentHeldSnap()
        guard hasMotion else { return }
        reconcileAndScroll()
    }

    /// A window resize: frames snap (or, `keepsMotion`, a running spring is carried into the new size: each frame and
    /// its target move together, `AnimatedFrame.rebase`, so the panes follow the resize in this frame and only what
    /// the spring had left still springs), and the scroll keeps the focused column in place on screen, then fits it (L7).
    fileprivate func reconcileAndScroll(keepsMotion: Bool = false) {
        reconcile(animated: keepsMotion, rebasing: keepsMotion, presents: false)
        if !(syncScroll(focused: lastFocused, source: .programmatic, mode: context.model.centerFocusedColumn, animated: keepsMotion) && hasMotion) { holdsContentForKeyResize = false } // a snap
    }

    // MARK: Model updates

    /// Applies a new layout. Returns true if springs need frames.
    ///
    /// A structural change (a split, a close, a zoom, an unzoom, a pane moved, a new dock column) is one commit: its
    /// end is known when it starts, so every pane and divider snaps to its place in the new layout and the screen shows
    /// them all in one presented frame (`ScreenContentView+SnapFrame`). No frame shows a pane between the two layouts,
    /// or content at another size than its pane gives it. A zoom keeps the panes it leaves, hidden, for the unzoom
    /// (`LayoutViewContext.Retirement.zoom`).
    /// Ratio and width changes (equalize, width presets, another client's
    /// divider drag) keep their spring. The cameras are `syncScroll`'s: a removed column or row leaves no camera past
    /// the end of what stays (`ColumnScrollState.reduce`), and a reveal of the focused pane inside that range moves
    /// whole panes and changes no size.
    /// `snapWaitsForFrame`: the root runs frames, so a change that snaps and resizes a pane shows at the next tick, its
    /// content drawn at its new size (`ScreenContentView+SnapFrame`).
    @discardableResult
    func update(layout: ScreenLayout, zoomed: Bool = false, canvas: CanvasScreen? = nil, animated: Bool, snapWaitsForFrame: Bool = false) -> Bool {
        // Into or out of a canvas, frames change coordinate space (the camera is the bounds): they snap.
        let animated = updateCanvas(canvas, animated: animated) && animated
        let structural = !self.layout.hasSameStructure(as: layout)
        let unzooming = self.zoomed && !zoomed
        let zooming = !self.zoomed && zoomed
        #if DEBUG
        let shapeBefore = structural && !isHidden && canvas == nil && !self.zoomed && !zoomed ? restColumns : nil
        #endif
        // A structural change during a key-resize spring takes the screen over: the panes on that spring keep moving
        // on the new one without starting it, so their key hold ends here (one pass per change, not per frame).
        if structural || zooming || unzooming, holdsContentForKeyResize {
            holdsContentForKeyResize = false
            for pane in self.layout.panes {
                guard let host = context.hosts[pane], host.superview === self else { continue }
                host.endKeyResizeHold()
            }
        }
        self.layout = layout
        self.zoomed = zoomed
        scrollSyncIsStructural = structural
        // The release's intent is in this layout (or was refused).
        if activeDrag == nil { rowDragPreview = nil }
        let moving = reconcile(animated: animated, structural: structural, zooming: zooming, presents: false,
                               snapWaitsForFrame: snapWaitsForFrame)
        // A structural change took the screen over from a key resize's spring: its pane views post again.
        if structural { releasePaneFrameNoticesIfSettled() }
        #if DEBUG
        if let shapeBefore { columnWidths.noteChange(from: shapeBefore, to: restColumns, viewportWidth: bounds.width) }
        #endif
        // The key-resize hold is the press's own: a structural change (a split, a close, a zoom) takes the screen over,
        // and a press that did not spring (Reduce Motion, pane animations off, a snap) ends it now.
        if structural || !moving { holdsContentForKeyResize = false } else if holdsContentForKeyResize, !paneFrameNotices.isHolding { paneFrameNotices.hold(displayedHosts) }
        return moving || canvasState.camera.isMoving
    }

    @discardableResult
    /// `rebasing`: the change is the viewport's, not the layout's (the sidebar's slide resizing the screen under a
    /// running split): a frame on a spring moves with its target (`AnimatedFrame.rebase`) instead of chasing it, so
    /// the panes ride the moving edge in its frame (Leo 2026-11-05: "the main pane waits for the right pane").
    func reconcile(animated: Bool, rebasing: Bool = false, structural: Bool = false, zooming: Bool = false,
                   presents: Bool = true, snapWaitsForFrame: Bool = false) -> Bool {
        let shown = rowDragPreview.map { layout.settingRowHeights($0.heights, for: $0.column) } ?? layout
        let before = geometry
        // One style read per pass: it is resolved from the settings.
        let style = context.style
        reconcilePasses += 1
        applyCamera()
        reconciledScale = scale
        baseGeometry = canvasGeometry ?? ScreenGeometry.compute(shown, viewport: bounds.size, style: style, scale: scale)
        geometry = baseGeometry.shiftingAreas(areaOffsets).shiftingRows(rowOffsets)
        // A structural change (a split, a close, a zoom, an unzoom, a pane moved) is one commit: its end is known when
        // it starts, so no pane and no divider of it shows between the two layouts. Every frame snaps to its place in
        // the new layout, and the screen shows them all in one pass (`ScreenContentView+SnapFrame`).
        let animate = animated && !context.reduceMotion && bounds.width > 0 && !structural
        // `ui.paneAnimations` (default on): a released divider springs only with it on.
        let splits = animate && context.animatesPaneLayout
        let targetsBefore = (panes: paneFrames.mapValues(\.targetRect), dividers: dividerFrames.mapValues(\.targetRect)) // M4
        // An animated width or ratio change (a preset, an equalize) is carried: its camera may re-anchor (M8).
        // A viewport resize under a spring (`rebasing`) is not: each frame moves with its target, and putting it
        // back where it showed (`settleCarried`) would undo that and leave it chasing the moved target.
        let carried = animate && !rebasing
        // Strip springs run in strip coordinates and fixed ones in the view's: a moved strip origin (a dock
        // that came or went) or a pane changing sides (a zoom shows its pane fixed) keeps it where it showed.
        let offset = scroll.value
        func shift(_ geometry: ScreenGeometry, _ pane: PaneID) -> CGFloat { geometry.scrolls(pane: pane) ? geometry.viewShift(offset: offset) : 0 }
        let drift = carried ? before.viewShift(offset: offset) - baseGeometry.viewShift(offset: offset) : 0
        (carriedShown, carriedDividers) = ([:], [:])
        // A release seeds only the layout it made (`releasedDivider` from this gesture, not a stale one).
        if let released = releasedDivider, CACurrentMediaTime() - released.time > 0.5 { releasedDivider = nil }
        let animateFrames = animate && (releasedDivider == nil || splits)
        // A structural change that snaps may show at the next tick, its terminals drawn ahead (CLOSE MOTION 3); so may a
        // keyboard resize press that snaps (Reduce Motion, pane animations off), its terminals drawn ahead with their grids
        // (RESIZE P0 13, KEY SNAP GRID).
        let keySnap = holdsContentForKeyResize && !structural
        let holdsSnap = snapWaitsForFrame && (structural || keySnap) && !animateFrames

        // Panes.
        for (pane, target) in baseGeometry.panes {
            if var existing = paneFrames[pane] {
                if carried {
                    carriedShown[pane] = existing.x.value + shift(before, pane)
                    existing.x.value += shift(before, pane) - shift(baseGeometry, pane)
                }
                if rebasing, !structural, existing.rect != existing.targetRect { existing.rebase(onto: target) }
                place(&existing, at: target, animated: animateFrames)
                paneFrames[pane] = existing
            } else {
                // A pane the layout gets: a new one, a close taken back before its host went, or one a zoom covered. One
                // that comes back hidden shows in the pass that places it (`showSnapReturning`), never a frame before
                // it at the place it had.
                let host = context.host(for: pane)
                if host.isHidden { frameInput.snapReturning.append(pane) }
                if host.superview !== self {
                    // Under the dividers: the pass that shows this change ranks it (`beginShowingChange`, `ensureStacking`).
                    addSubview(host, positioned: .below, relativeTo: firstDividerView)
                }
                // Opaque and in its place from the first frame that shows it.
                paneFrames[pane] = AnimatedFrame(target)
            }
            context.hosts[pane]?.applyShape(padding: style.panePadding, cornerRadius: style.paneCornerRadius, wholeCard: style.floatingPanes)
        }
        // Out of a zoom: the covered panes it kept that this layout did not take back (closed while zoomed) go now.
        if structural, !zoomed { context.releaseRetired(of: screenID, until: .zoom) }
        for pane in paneFrames.keys where baseGeometry.panes[pane] == nil {
            paneFrames[pane] = nil
            // A pane that moved to another screen belongs to that screen now. A pane that left the layout stays as it
            // shows until this change shows (`hideSnapDeparted`: no frame shows the old layout without it) and hides in
            // that pass. A zoom keeps the panes it leaves, hidden, for the unzoom (`LayoutViewContext.Retirement.zoom`);
            // a close's go (`releaseDeparted`).
            guard zooming || !context.livePanes.contains(pane) else { continue }
            if context.hosts[pane]?.superview === self {
                context.retire(pane, from: screenID, until: zooming ? .zoom : .landing, shownAtRank: liveRank(of: pane, in: before))
                frameInput.snapDeparted.append(pane)
            } else if !zooming {
                context.release(pane)
            }
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
                if case let .split(split) = kind {
                    view.contextMenu = { [weak self] in self?.context.dividerMenu?(split) }
                    view.isLineHidden = hiddenDividers.contains(split)
                }
                addSubview(view)
                dividerViews[kind] = view
            }
            view.lineThickness = style.dividerThickness
            view.showsIdleLine = showsIdleLine(kind)
            view.showsActiveLine = style.showsDividerFeedback
            if var frame = dividerFrames[kind] {
                if scrolls(kind) {
                    if carried { carriedDividers[kind] = frame.x.value + before.viewShift(offset: offset) }
                    frame.x.value += drift
                }
                if rebasing, !structural, frame.rect != frame.targetRect { frame.rebase(onto: target.rect) }
                place(&frame, at: target.rect, animated: animateFrames)
                dividerFrames[kind] = frame
            } else if case .columnEdge = kind,
                      let index = renamedEdges.firstIndex(where: { abs($0.targetRect.minX - target.rect.minX) < 0.5 && abs($0.targetRect.width - target.rect.width) < 0.5 }) {
                var frame = renamedEdges.remove(at: index)
                place(&frame, at: target.rect, animated: animateFrames)
                dividerFrames[kind] = frame
            } else {
                // A new divider is in its place in the first frame that shows it.
                dividerFrames[kind] = AnimatedFrame(target.rect, alpha: 1)
            }
        }
        for kind in dividerViews.keys where targets[kind] == nil {
            // The handle under a drag goes away: its mouse-up never comes.
            if activeDrag?.kind == kind { endDrag() }
            // It shows where it was, and takes no drag, until this change shows (`hideSnapDeparted`).
            if let view = dividerViews.removeValue(forKey: kind) {
                view.onDrag = nil
                frameInput.snapDepartedDividers.append(view)
            }
            dividerFrames[kind] = nil
        }

        if let released = releasedDivider {
            releasedDivider = nil
            if animateFrames, splits, let divider = dividerFrames[released.kind] {
                SplitMotion.seed(velocity: released.velocity, along: dividerViews[released.kind]?.axis ?? .horizontal, divider: divider,
                                 panes: &paneFrames, dividers: &dividerFrames, moved: Set(paneFrames.keys.filter { targetsBefore.panes[$0] != paneFrames[$0]?.targetRect }),
                                 movedDividers: Set(dividerFrames.keys.filter { targetsBefore.dividers[$0] != dividerFrames[$0]?.targetRect }), edges: released.sharedEdges ? targetsBefore : nil)
            }
        }

        // The docks' backdrops and the stacking order are part of what a frame shows: they change in the pass that shows
        // this change, with its panes (`beginShowingChange`), not here.
        frameInput.dockIsStale = true
        // The scroll follows in `syncScroll`, which the root calls with the focus after every update, and presents.
        // Only a structural change re-places everything: a ratio, width or row-height change (every divider
        // drag step, an equalize) moves only the panes whose frames changed, and every per-pane input (frame,
        // alpha, clip range, covers, divider clips) is compared in the pass (`applyPresentation`).
        if structural { forcesPresentation = true }
        // A change that snaps shows at the next frame tick when it resizes a pane. Else it shows in this turn, or, when
        // the turn holds its presentations (a key's sync, a frame tick's input), in the pass that turn asked for. What
        // the change took out goes in the pass that places the panes, never a turn before it.
        if holdsSnap { _ = holdsSnapForContent(keyPress: keySnap) }
        if !frameInput.snapWaitsForContent, !context.holdsPresentations { beginShowingChange() }
        if presents { applyPresentation() }
        let moving = animate && hasMotion
        if !(moving && holdsGrids) { holdsGrids = false }
        return moving
    }

    /// The panes and strip dividers an animated width or ratio change carried (a preset, an equalize) start where they
    /// showed before it, now that the camera is where the new layout puts it. A structural change carries none: each
    /// of its panes is at its place in the frame that shows it.
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
        paneFrameNotices.release()
        holdsGrids = false
        for pane in paneFrames.keys where !context.livePanes.contains(pane) {
            context.release(pane)
        }
        paneFrames.removeAll()
        frameInput.snapWaitsForContent = false
        hideSnapDeparted()
        // Every host the screen kept goes with it, now: a close's, and the panes a zoom kept for its unzoom.
        releaseDeparted(until: nil)
    }
}
