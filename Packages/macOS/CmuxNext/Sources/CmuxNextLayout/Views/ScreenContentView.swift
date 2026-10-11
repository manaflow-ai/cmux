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
    private var paneFrames: [PaneID: AnimatedFrame] = [:]
    private(set) var dividerViews: [DividerHandleView.Kind: DividerHandleView] = [:]
    private var dividerFrames: [DividerHandleView.Kind: AnimatedFrame] = [:]
    /// Panes growing in from a split's edge (`PaneArrival.presentation`), and the dock columns that change added.
    private var arriving: Set<PaneID> = [], newDockColumns: Set<ColumnID> = []
    /// A zoom's other panes, left where they showed under the zoomed pane as it grows over them,
    /// and released once it settles (`releaseCovered`); an unzoom before then takes them back.
    private(set) var covered: Set<PaneID> = []

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
    /// left by a close, a zoom or a move away spring to their places (`PaneArrival.departing`); an
    /// unzoom springs the zoomed pane back over the others, which wait in place under it.
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
        let arrivals = animate && structural && !unzooming
            ? PaneArrival.split(paneFrames.mapValues(\.targetRect), from: before, to: baseGeometry, offset: scroll.value) : [:]
        let departing = animate && structural && arrivals.isEmpty && PaneArrival.departing(paneFrames.keys, to: baseGeometry.panes.keys)
        // An unzoom: the other panes come back in place under the zoomed one, which springs back to its slot.
        let revealing = animate && structural && unzooming
        // A zoom: the other panes stay under the zoomed one until it covers them, rather than leaving a hole.
        let covering = animate && structural && zooming
        covered.subtract(baseGeometry.panes.keys)
        let carried = !arrivals.isEmpty || departing || revealing
        // Strip springs run in strip coordinates and fixed ones in the view's: a moved strip origin (a dock
        // that came or went) or a pane changing sides (a zoom shows its pane fixed) keeps it where it showed.
        let offset = scroll.value
        func shift(_ geometry: ScreenGeometry, _ pane: PaneID) -> CGFloat { geometry.scrolls(pane: pane) ? geometry.viewShift(offset: offset) : 0 }
        let drift = carried ? before.viewShift(offset: offset) - baseGeometry.viewShift(offset: offset) : 0
        (carriedShown, carriedDividers) = ([:], [:])
        let animateFrames = animate && (!structural || carried)
        // Under the zoomed pane, which every pane coming back waits beneath.
        let revealAnchor = revealing ? paneFrames.keys.compactMap { context.hosts[$0] }.first { $0.superview === self } : nil
        if structural { (arriving, newDockColumns) = (Set(arrivals.keys), PaneArrival.newDocks(arrivals, from: before, to: baseGeometry)) }

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
                paneFrames[pane] = existing
            } else {
                let host = context.host(for: pane)
                if host.superview !== self {
                    addSubview(host, positioned: .below, relativeTo: revealAnchor ?? firstDividerView)
                }
                var frame = AnimatedFrame(arrivals[pane]?.seed ?? target)
                frame.setTarget(target)
                paneFrames[pane] = frame
            }
            context.hosts[pane]?.applyShape(padding: style.panePadding, cornerRadius: style.paneCornerRadius)
        }
        for pane in paneFrames.keys where baseGeometry.panes[pane] == nil {
            paneFrames[pane] = nil
            if covering, context.hosts[pane]?.superview === self {
                covered.insert(pane)
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
            view.showsIdleLine = context.style.showsDividerLine
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

        reconcileDock()
        // The scroll follows in `syncScroll`, which the root calls with the
        // focus after every update (ColumnScrollState.reduce).
        applyPresentation()
        let moving = animate && hasMotion
        if !moving { releaseCovered() }
        return moving
    }

    /// Lets go of a zoom's covered panes once nothing moves over them.
    private func releaseCovered() {
        guard !covered.isEmpty else { return }
        for pane in covered where paneFrames[pane] == nil && !context.livePanes.contains(pane) {
            context.release(pane)
        }
        covered.removeAll()
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
        return paneFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
            || dividerFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
    }

    /// Advances springs by `dt`. Returns true while anything still moves.
    func step(_ dt: Double) -> Bool {
        var moving = false
        for key in Array(paneFrames.keys) {
            if paneFrames[key]?.advance(dt, parameters: Motion.spring(.move)) == true { moving = true }
        }
        // The zoomed pane covers the others now.
        if !moving { releaseCovered() }
        for key in Array(dividerFrames.keys) {
            if dividerFrames[key]?.advance(dt, parameters: Motion.spring(.move)) == true { moving = true }
        }
        if stepRows(dt) { moving = true }
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
            let revealing = arriving.contains(pane) ? frame.rect.offsetBy(dx: shift.dx, dy: shift.dy) : nil
            host.frame = (revealing == nil ? frame.rect : PaneArrival.presentation(shown: frame.rect, target: frame.targetRect)).offsetBy(dx: shift.dx, dy: shift.dy)
            host.alphaValue = frame.alpha.value
            host.isDocked = !scrolls
            clips.append((host, scrolls, revealing))
        }
        // Once every frame is placed: a pane is clipped by the panes in front of it.
        for (host, scrolls, revealing) in clips { clipToStrip(host, scrolls: scrolls, clip: clip, revealing: revealing) }
        for pane in covered {
            if let host = context.hosts[pane], host.superview === self { clipToStrip(host, scrolls: false, clip: nil) }
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

    // MARK: Chrome

    /// Focus ring, inactive dim and attention rings. Overlay-only: no pane
    /// frame or inset depends on any of it.
    func updateChrome(focused: PaneID?, dimsInactive: Bool, attention: [PaneID: AttentionMark], animated: Bool) {
        let multiple = paneFrames.count > 1
        let style = context.style
        let ringAllowed = (multiple || style.focusRing.showsForSinglePane)
            && style.focusIndicator.marksBorder
            // Pointer and scroll focus should not leave a keyboard-only focus ring behind.
            && context.model.lastFocusSource != .pointer
            && context.model.lastFocusSource != .scroll
        for pane in paneFrames.keys {
            guard let host = context.hosts[pane] else { continue }
            let isFocused = pane == focused
            host.setChrome(
                showsRing: ringAllowed && isFocused,
                // With appearance.borders none the ring is off; the dim stands in
                // for it when the indicator asked for the border and nothing else.
                dim: multiple && (dimsInactive || (!style.drawsLines && style.focusIndicator == .border)) && !isFocused
                    ? style.inactivePaneDimming : 0,
                focusRing: style.focusRing,
                ringAlphaOverride: style.focusRingAlphaOverride,
                tabEmphasis: .forPane(isFocused: isFocused, paneCount: paneFrames.count, indicator: style.focusIndicator,
                                      style: style.inactiveTabStyle, strength: style.inactiveTabStrength),
                border: PaneOverlayView.Border(shows: style.showsPaneBorder, width: style.paneBorderWidth, color: style.paneBorderColor),
                attention: attention[pane],
                attentionSettings: style.attention,
                animated: animated
            )
        }
    }

    // MARK: Visibility and hit testing

    /// Panes whose displayed frame intersects the viewport.
    func visiblePanes() -> Set<PaneID> {
        var result: Set<PaneID> = []
        let uncovered = uncoveredRect
        for (pane, frame) in paneFrames {
            // A strip pane wholly under a docked column is hidden.
            let scrolls = geometry.scrolls(pane: pane)
            let displayed = displayedRect(frame.rect, pane: pane)
            let overlap = displayed.intersection(scrolls ? uncovered : bounds)
            if !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5, frame.alpha.value > 0.01 {
                result.insert(pane)
            }
        }
        return result
    }

    /// Panes whose displayed frame lies within one viewport width of the
    /// viewport on either side (architecture.md 4): visible panes plus the
    /// off-screen columns a short scroll brings in. Their content stays
    /// alive, paused, so scrolling back shows it at once.
    func keepAlivePanes() -> Set<PaneID> {
        KeepAliveBand.panes(displayed: paneFrames.reduce(into: [:]) { $0[$1.key] = displayedRect($1.value.rect, pane: $1.key) },
                            viewport: bounds)
    }

    /// The pane under `localPoint`: a docked column's pane above the strip.
    func pane(at localPoint: NSPoint) -> PaneID? {
        if geometry.dock.contains(where: { $0.cover.contains(localPoint) }) {
            return geometry.panes.first { !geometry.scrolls(pane: $0.key) && $0.value.contains(localPoint) }?.key
        }
        let content = CGPoint(x: localPoint.x - stripShift, y: localPoint.y)
        return geometry.panes.first { geometry.scrolls(pane: $0.key) && $0.value.contains(content) }?.key
    }

    /// Displayed frame of `pane` in local coordinates.
    func displayedFrame(of pane: PaneID) -> CGRect? {
        paneFrames[pane].map { displayedRect($0.rect, pane: pane) }
    }

    /// Releases every hosted pane that is not live elsewhere (screen removed).
    func tearDown() {
        // A drag on a screen that goes away gets no release either.
        endDrag()
        for pane in paneFrames.keys where !context.livePanes.contains(pane) {
            context.release(pane)
        }
        paneFrames.removeAll()
        releaseCovered()
    }
}
