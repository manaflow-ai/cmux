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
    /// `baseGeometry` at the presented row offsets (`shiftingRows`): what
    /// hit testing, drops, focus and the strip scroll read.
    var geometry: ScreenGeometry
    private(set) var paneFrames: [PaneID: AnimatedFrame] = [:]
    private(set) var dividerViews: [DividerHandleView.Kind: DividerHandleView] = [:]
    private(set) var dividerFrames: [DividerHandleView.Kind: AnimatedFrame] = [:]
    /// Panes growing in from a split's edge (`PaneArrival.presentation`), and the dock columns that change added.
    private var arriving: Set<PaneID> = [], newDockColumns: Set<ColumnID> = []
    /// A zoom or unzoom: the pane that owns the motion, and the panes a zoom leaves fading out under it.
    private(set) var zoomMotion = PaneZoomMotion()
    var covered: Set<PaneID> { Set(zoomMotion.leaving.keys) }
    /// Split motion moves layers only (DESIGN P4): while a split or a close springs, each pane that
    /// changes size keeps one host frame (`SplitMotion.heldFrame`), so its terminal or page lays
    /// out once, and is clipped to the frame the spring presents.
    private var heldFrames: [PaneID: CGRect] = [:]
    /// A divider released with this pointer velocity (pt/s along its axis): the next layout's
    /// spring starts from it (`SplitMotion.seed`).
    var releasedDivider: (kind: DividerHandleView.Kind, velocity: CGFloat, time: CFTimeInterval)?

    /// Column scroll rules and state (`ColumnScrollState.reduce`).
    var scrollState = ColumnScrollState()
    /// Each column whose rows overflow scrolls vertically with its own
    /// instance of the same rules (ScreenContentView+Rows.swift).
    var rowScrolls: [ColumnID: RowScroll] = [:]
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
    /// Overlay docked columns' glass rims, keyed by column.
    var backdrops: [ColumnID: DockBackdropView] = [:]
    /// The strip scrollbar; created on first use.
    var scrollbar: StripScrollbarView?
    /// The offset the scrollbar last showed, and whether the next change
    /// came from scrolling (it flashes the scrollbar).
    var scrollbarOffset: CGFloat?
    var scrollbarFlash = false

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

    override var isFlipped: Bool { true }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { reconcileAndScroll() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reconcileAndScroll()
    }

    /// A window resize: frames snap, and the scroll keeps the focused column
    /// in place on screen, then fits it (L7).
    private func reconcileAndScroll() {
        reconcile(animated: false)
        syncScroll(focused: lastFocused, source: .programmatic, mode: context.model.centerFocusedColumn, animated: false)
    }

    // MARK: Model updates

    /// Applies a new layout. Returns true if springs need frames.
    ///
    /// A split or a new dock column grows in from its edge (`PaneArrival`, cx-f6i7;
    /// a dock moves the strip's origin, so strip frames start where they show), and the panes
    /// left by a close or a move away spring to their places (`PaneArrival.departing`); a zoom and
    /// an unzoom move as `PaneZoomMotion` says (the other panes fade under the zoomed one).
    /// Other structural changes snap.
    /// Ratio and width changes (equalize, width presets, another client's
    /// divider drag) keep their spring. The strip scroll (including the
    /// spring back after the last column closes) is `syncScroll`'s.
    @discardableResult
    func update(layout: ScreenLayout, zoomed: Bool = false, animated: Bool) -> Bool {
        let structural = !self.layout.hasSameStructure(as: layout)
        let unzooming = self.zoomed && !zoomed
        let zooming = !self.zoomed && zoomed
        self.layout = layout
        self.zoomed = zoomed
        // The release's intent is in this layout (or was refused).
        if activeDrag == nil { rowDragPreview = nil }
        return reconcile(animated: animated, structural: structural, unzooming: unzooming, zooming: zooming)
    }

    @discardableResult
    func reconcile(animated: Bool, structural: Bool = false, unzooming: Bool = false, zooming: Bool = false) -> Bool {
        let shown = rowDragPreview.map { layout.settingRowHeights($0.heights, for: $0.column) } ?? layout
        let before = geometry
        baseGeometry = ScreenGeometry.compute(shown, viewport: bounds.size, style: context.style, scale: scale)
        geometry = baseGeometry.shiftingRows(rowOffsets)
        let animate = animated && !context.reduceMotion && bounds.width > 0
        // `ui.paneAnimations` (default off): a split, a close and a released divider spring only with it on.
        let splits = animate && context.animatesPaneLayout
        let arrivals = splits && structural && !unzooming
            ? PaneArrival.split(paneFrames.mapValues(\.targetRect), from: before, to: baseGeometry, offset: scroll.value) : [:]
        let departing = (zooming ? animate : splits) && structural && arrivals.isEmpty
            && PaneArrival.departing(paneFrames.keys, to: baseGeometry.panes.keys)
        // An unzoom: the other panes come back in place under the zoomed one, which springs back to its slot.
        let revealing = animate && structural && unzooming
        // A zoom: the other panes fade out under the zoomed one (`PaneZoomMotion`), rather than leaving a hole.
        let covering = animate && structural && zooming
        if structural { zoomMotion.begin(covering ? baseGeometry.panes.keys.first : revealing ? paneFrames.keys.first { baseGeometry.panes[$0] != nil } : nil, zooming: covering, frames: paneFrames, to: baseGeometry) }
        // A split still springing when the next structural update lands (the daemon's echo of the
        // split moves the tab into the new pane ~75 ms in) keeps springing from where it shows,
        // with its velocity, instead of snapping to the end (hq-1d: Cmd-D measured 4 frames).
        let inFlight = splits && structural && arrivals.isEmpty && !departing
            && paneFrames.values.contains { $0.rect != $0.targetRect }
        let carried = !arrivals.isEmpty || departing || revealing
        // Strip springs run in strip coordinates and fixed ones in the view's: a moved strip origin (a dock
        // that came or went) or a pane changing sides (a zoom shows its pane fixed) keeps it where it showed.
        let offset = scroll.value
        func shift(_ geometry: ScreenGeometry, _ pane: PaneID) -> CGFloat { geometry.scrolls(pane: pane) ? geometry.viewShift(offset: offset) : 0 }
        let drift = carried ? before.viewShift(offset: offset) - baseGeometry.viewShift(offset: offset) : 0
        (carriedShown, carriedDividers) = ([:], [:])
        // A release seeds only the layout it made (`releasedDivider` from this gesture, not a stale one).
        if let released = releasedDivider, CACurrentMediaTime() - released.time > 0.5 { releasedDivider = nil }
        let animateFrames = animate && (!structural || carried || inFlight) && (releasedDivider == nil || splits)
        // Under the zoomed pane, which every pane coming back waits beneath.
        let revealAnchor = revealing ? paneFrames.keys.compactMap { context.hosts[$0] }.first { $0.superview === self } : nil
        if structural, !inFlight { (arriving, newDockColumns) = (Set(arrivals.keys), PaneArrival.newDocks(arrivals, from: before, to: baseGeometry)) }

        // Panes.
        let style = context.style
        for (pane, target) in baseGeometry.panes {
            if var existing = paneFrames[pane] {
                if carried {
                    carriedShown[pane] = existing.x.value + shift(before, pane)
                    existing.x.value += shift(before, pane) - shift(baseGeometry, pane)
                }
                existing.setTarget(target, alpha: 1)
                if !animateFrames { existing.snap() }
                heldFrames[pane] = animateFrames ? SplitMotion.heldFrame(shown: existing.rect, target: target) : nil
                paneFrames[pane] = existing
            } else {
                let host = context.host(for: pane)
                if host.superview !== self {
                    addSubview(host, positioned: .below, relativeTo: revealAnchor ?? firstDividerView)
                }
                var frame = AnimatedFrame(arrivals[pane]?.seed ?? target)
                if let back = zoomMotion.returning(pane, revealing: revealing) { frame.alpha = back }
                frame.setTarget(target, alpha: 1)
                paneFrames[pane] = frame
            }
            context.hosts[pane]?.applyShape(padding: style.panePadding, cornerRadius: style.paneCornerRadius, wholeCard: style.floatingPanes)
        }
        for pane in paneFrames.keys where baseGeometry.panes[pane] == nil {
            let frame = paneFrames.removeValue(forKey: pane)
            heldFrames[pane] = nil
            if covering, context.hosts[pane]?.superview === self, let frame {
                zoomMotion.leave(pane, frame)
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
        for (kind, target) in targets {
            let view: DividerHandleView
            if let existing = dividerViews[kind] {
                view = existing
                view.setAxis(target.axis)
            } else {
                view = DividerHandleView(kind: kind, axis: target.axis)
                view.onDrag = { [weak self] event in self?.handleDrag(kind: kind, event: event) }
                view.onPointerChange = { [weak self] in self?.refreshDividerHover() }
                addSubview(view)
                dividerViews[kind] = view
            }
            view.lineThickness = context.style.dividerThickness
            view.showsIdleLine = switch kind {
            case .rowEdge: context.style.showsRowSeparator
            default: context.style.showsDividerLine
            }
            view.showsActiveLine = context.style.showsDividerFeedback
            if var frame = dividerFrames[kind] {
                if scrolls(kind) {
                    if carried { carriedDividers[kind] = frame.x.value + before.viewShift(offset: offset) }
                    frame.x.value += drift
                }
                frame.setTarget(target.rect, alpha: 1)
                if !animateFrames { frame.snap() }
                dividerFrames[kind] = frame
            } else {
                // A split's new divider starts on the edge its pane grows from; an unzoom's fade in
                // as the zoomed pane springs back, rather than showing over it.
                let edge = arrivals.values.first?.edgeOffset ?? .zero
                var frame = AnimatedFrame(target.rect.offsetBy(dx: edge.dx, dy: edge.dy), alpha: revealing ? 0 : 1)
                frame.setTarget(target.rect, alpha: 1)
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
                                 panes: &paneFrames, dividers: &dividerFrames)
            }
        }

        reconcileDock()
        // The scroll follows in `syncScroll`, which the root calls with the
        // focus after every update (ColumnScrollState.reduce).
        applyPresentation()
        let moving = animate && hasMotion
        if !moving { releaseCovered() }
        return moving
    }

    /// Lets go of the panes a zoom left as each one's fade ends (every one with `all`).
    private func releaseCovered(all: Bool = false) {
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

    private var firstDividerView: NSView? {
        subviews.first { $0 is DividerHandleView }
    }

    // MARK: Animation

    private var hasMotion: Bool {
        if !isUserScrolling && (scroll.value != scroll.target || scroll.velocity != 0) { return true }
        if rowsMoving { return true }
        return zoomMotion.isMoving || paneFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
            || dividerFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
    }

    /// Advances springs by `dt`. Returns true while anything still moves.
    func step(_ dt: Double) -> Bool {
        var moving = false
        for key in Array(paneFrames.keys) {
            if paneFrames[key]?.advance(dt, parameters: Motion.spring(zoomMotion.spring(for: key))) == true { moving = true }
        }
        if zoomMotion.advance(dt) { moving = true }
        releaseCovered()
        for key in Array(dividerFrames.keys) {
            if dividerFrames[key]?.advance(dt, parameters: Motion.spring(.move)) == true { moving = true }
        }
        if stepRows(dt) { moving = true }
        if MotionTrace.isEnabled { MotionTrace.sample("layout.travel", Double(travelLeft)) }
        if !isUserScrolling {
            if scroll.advance(dt, parameters: Motion.spring(.scroll), epsilon: 0.25) {
                moving = true
                scrollbarFlash = true
            } else if reportScrollOnSettle {
                reportScrollOnSettle = false
                reportLeadingColumn()
            }
        }
        applyPresentation()
        return moving
    }

    /// New dock columns' panes still growing in from their screen edge (their frames).
    var growingDocks: [AnimatedFrame] { PaneArrival.growing(arriving, frames: paneFrames, in: geometry, docks: newDockColumns) }

    func applyPresentation() {
        let strip = stripShift
        let uncovered = uncoveredRect, clip = PaneArrival.stripClip(geometry, docks: growingDocks)
        var clips: [(host: PaneHostView, scrolls: Bool, revealing: CGRect?)] = []
        for (pane, frame) in paneFrames {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            let scrolls = geometry.scrolls(pane: pane)
            let shift = CGVector(dx: scrolls ? strip : 0, dy: -rowOffset(of: pane))
            if arriving.contains(pane), frame.rect == frame.targetRect { arriving.remove(pane) }
            if heldFrames[pane] != nil, frame.rect == frame.targetRect { heldFrames[pane] = nil }
            let held = heldFrames[pane]
            // The zooming pane keeps its full size under its spring rect (`PaneZoomMotion`); an arriving
            // pane slides in at its final size; a held one keeps its frame. Each shows only the presented
            // rect (a split's: the padded content, rounded as at rest).
            let zoomed = zoomMotion.presentation(of: pane, frame)
            let revealing = zoomed != nil ? frame.rect.offsetBy(dx: shift.dx, dy: shift.dy)
                : arriving.contains(pane) || held != nil
                ? SplitMotion.visible(frame.rect, padding: host.padding).offsetBy(dx: shift.dx, dy: shift.dy) : nil
            let placed = (zoomed ?? held ?? (arriving.contains(pane) ? PaneArrival.presentation(shown: frame.rect, target: frame.targetRect) : frame.rect))
                .offsetBy(dx: shift.dx, dy: shift.dy)
            if host.frame != placed { host.frame = placed }
            (host.alphaValue, host.isDocked, host.revealRect) = (frame.alpha.value, !scrolls, revealing)
            clips.append((host, scrolls, revealing))
        }
        // Once every frame is placed: a pane is clipped by the panes in front of it.
        for (host, scrolls, revealing) in clips { clipToStrip(host, scrolls: scrolls, clip: clip, revealing: revealing) }
        for (pane, alpha) in zoomMotion.opacities {
            if let host = context.hosts[pane], host.superview === self { host.alphaValue = alpha; clipToStrip(host, scrolls: false, clip: nil) }
        }
        for (kind, frame) in dividerFrames {
            guard let view = dividerViews[kind] else { continue }
            let scrolls = self.scrolls(kind)
            view.frame = frame.rect.offsetBy(dx: scrolls ? strip : 0, dy: -rowOffset(of: kind))
            view.alphaValue = frame.alpha.value
            // A strip divider under a docked column must not take its clicks.
            let hidden = scrolls && !geometry.dock.isEmpty && view.frame.intersection(uncovered).width < 0.5
            if view.isHidden != hidden { view.isHidden = hidden }
        }
        updateScrollbar()
        refreshDividerHover()
        context.overlayNeedsSync()
    }

    /// Divider hover from the pointer and the current frames (`ScreenDividers`).
    func refreshDividerHover() { ScreenDividers(screen: self).refreshHover() }

    /// Hosts this screen displays now.
    var displayedHosts: [PaneHostView] {
        paneFrames.keys.compactMap { pane in
            context.hosts[pane].flatMap { $0.superview === self ? $0 : nil }
        }
    }

    var dividerMouseAreas: [LayoutMouseArea] { ScreenDividers(screen: self).mouseAreas }
    var dividerLineRects: [CGRect] { ScreenDividers(screen: self).lineRects }

    /// Releases every hosted pane that is not live elsewhere (screen removed).
    func tearDown() {
        // A drag on a screen that goes away gets no release either.
        endDrag()
        for pane in paneFrames.keys where !context.livePanes.contains(pane) {
            context.release(pane)
        }
        paneFrames.removeAll()
        heldFrames.removeAll()
        releaseCovered(all: true)
    }
}
