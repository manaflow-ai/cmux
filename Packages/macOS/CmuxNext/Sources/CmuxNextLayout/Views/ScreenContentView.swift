import AppKit
import CmuxNextDesign

/// Renders one screen: a split tree, or a horizontally scrolling strip of
/// columns. Pane and divider frames are springs in content space; the
/// displayed frame subtracts the scroll offset.
final class ScreenContentView: NSView {
    let screenID: ScreenID
    let context: LayoutViewContext

    private(set) var layout: ScreenLayout
    private(set) var geometry: ScreenGeometry
    private var paneFrames: [PaneID: AnimatedFrame] = [:]
    private var dividerViews: [DividerHandleView.Kind: DividerHandleView] = [:]
    private var dividerFrames: [DividerHandleView.Kind: AnimatedFrame] = [:]

    var scroll = SpringValue(0)
    /// Unbanded offset accumulated during a trackpad gesture.
    var rawScroll: CGFloat = 0
    var isUserScrolling = false
    var scrollSamples: [(time: TimeInterval, delta: CGFloat)] = []
    var reportScrollOnSettle = false

    var activeDrag: ActiveDrag?

    init(screenID: ScreenID, layout: ScreenLayout, context: LayoutViewContext) {
        self.screenID = screenID
        self.layout = layout
        self.context = context
        self.geometry = ScreenGeometry.compute(layout, viewport: .zero, style: context.style)
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
        if changed { reconcile(animated: false) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reconcile(animated: false)
    }

    // MARK: Model updates

    /// Applies a new layout. Returns true if springs need frames.
    ///
    /// A structural change (split, close, move, new column) lands in one
    /// frame: panes and dividers snap to their targets and a new pane is
    /// fully opaque at once, so its content can draw in the same frame.
    /// Ratio and width changes (equalize, width presets, another client's
    /// divider drag) and column reveal scrolls keep their spring.
    @discardableResult
    func update(layout: ScreenLayout, animated: Bool) -> Bool {
        let structural = !self.layout.hasSameStructure(as: layout)
        self.layout = layout
        return reconcile(animated: animated, structural: structural)
    }

    @discardableResult
    private func reconcile(animated: Bool, structural: Bool = false) -> Bool {
        geometry = ScreenGeometry.compute(layout, viewport: bounds.size, style: context.style, scale: scale)
        let animate = animated && !context.reduceMotion && bounds.width > 0
        let animateFrames = animate && !structural

        // Panes.
        let style = context.style
        for (pane, target) in geometry.panes {
            if var existing = paneFrames[pane] {
                existing.setTarget(target, alpha: 1)
                if !animateFrames { existing.snap() }
                paneFrames[pane] = existing
            } else {
                let host = context.host(for: pane)
                if host.superview !== self {
                    addSubview(host, positioned: .below, relativeTo: firstDividerView)
                }
                paneFrames[pane] = AnimatedFrame(target)
            }
            context.hosts[pane]?.applyShape(padding: style.panePadding, cornerRadius: style.paneCornerRadius)
        }
        for pane in paneFrames.keys where geometry.panes[pane] == nil {
            paneFrames[pane] = nil
            // A pane that moved to another screen belongs to that screen now.
            if !context.livePanes.contains(pane) { context.release(pane) }
        }

        // Dividers and column edges.
        var targets: [DividerHandleView.Kind: (rect: CGRect, axis: SplitAxis)] = [:]
        for divider in geometry.dividers { targets[.split(divider.id)] = (divider.hitFrame, divider.axis) }
        for edge in geometry.columnEdges { targets[.columnEdge(edge.column)] = (edge.hitFrame, .horizontal) }
        for (kind, target) in targets {
            let view: DividerHandleView
            if let existing = dividerViews[kind] {
                view = existing
                view.setAxis(target.axis)
            } else {
                view = DividerHandleView(kind: kind, axis: target.axis)
                view.onDrag = { [weak self] event in self?.handleDrag(kind: kind, event: event) }
                addSubview(view)
                dividerViews[kind] = view
            }
            view.lineThickness = context.style.dividerThickness
            view.showsIdleLine = context.style.showsDividerLine
            if var frame = dividerFrames[kind] {
                frame.setTarget(target.rect, alpha: 1)
                if !animateFrames { frame.snap() }
                dividerFrames[kind] = frame
            } else {
                dividerFrames[kind] = AnimatedFrame(target.rect)
            }
        }
        for kind in dividerViews.keys where targets[kind] == nil {
            dividerViews.removeValue(forKey: kind)?.removeFromSuperview()
            dividerFrames[kind] = nil
        }

        // Scroll. A clamp caused by a structural change (a closed column)
        // snaps with it; reveal scrolls requested afterwards still spring.
        let clamped = ColumnStripGeometry.clamp(scroll.target, contentWidth: geometry.contentWidth, viewportWidth: bounds.width)
        if clamped != scroll.target && !isUserScrolling {
            scroll.target = clamped
            if !animateFrames { scroll.snap() }
        }
        if !geometry.isColumns {
            scroll = SpringValue(0)
        }

        applyPresentation()
        return animate && hasMotion
    }

    private var firstDividerView: NSView? {
        subviews.first { $0 is DividerHandleView }
    }

    // MARK: Animation

    private var hasMotion: Bool {
        if !isUserScrolling && (scroll.value != scroll.target || scroll.velocity != 0) { return true }
        return paneFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
            || dividerFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
    }

    /// Advances springs by `dt`. Returns true while anything still moves.
    func step(_ dt: Double) -> Bool {
        var moving = false
        for key in Array(paneFrames.keys) {
            if paneFrames[key]!.advance(dt, parameters: Motion.spring(.move)) { moving = true }
        }
        for key in Array(dividerFrames.keys) {
            if dividerFrames[key]!.advance(dt, parameters: Motion.spring(.move)) { moving = true }
        }
        if !isUserScrolling {
            if scroll.advance(dt, parameters: Motion.spring(.scroll), epsilon: 0.25) {
                moving = true
            } else if reportScrollOnSettle {
                reportScrollOnSettle = false
                reportLeadingColumn()
            }
        }
        applyPresentation()
        return moving
    }

    func applyPresentation() {
        let dx = -scroll.value
        for (pane, frame) in paneFrames {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            host.frame = frame.rect.offsetBy(dx: dx, dy: 0)
            host.alphaValue = frame.alpha.value
        }
        for (kind, frame) in dividerFrames {
            guard let view = dividerViews[kind] else { continue }
            view.frame = frame.rect.offsetBy(dx: dx, dy: 0)
            view.alphaValue = frame.alpha.value
        }
        context.overlayNeedsSync()
    }

    /// Hosts this screen displays now.
    var displayedHosts: [PaneHostView] {
        paneFrames.keys.compactMap { pane in
            context.hosts[pane].flatMap { $0.superview === self ? $0 : nil }
        }
    }

    /// Divider hit areas that are on screen, in this view's coordinates.
    /// They take the mouse but draw only their thin line, so content drawn
    /// above the window (a Chromium page) keeps drawing under them.
    var dividerMouseAreas: [LayoutMouseArea] {
        dividerViews.compactMap { kind, view in
            guard !view.isHidden, view.alphaValue > 0.01 else { return nil }
            let rect = view.frame.intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { return nil }
            return LayoutMouseArea(id: kind.mouseAreaID, rect: rect, resizesColumns: view.axis == .horizontal)
        }.sorted { $0.id < $1.id }
    }

    /// The dividers' drawn lines, in this view's coordinates: native UI that
    /// Chromium pages leave uncovered (they sit in the gap between panes).
    var dividerLineRects: [CGRect] {
        dividerViews.values.compactMap { view in
            guard !view.isHidden, view.alphaValue > 0.01 else { return nil }
            let rect = view.lineFrameInSuperview.intersection(bounds)
            return rect.isNull || rect.isEmpty ? nil : rect
        }.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
    }

    /// Hover forwarded from a click-catching panel over a page.
    func setDividerHovered(_ id: String, _ hovered: Bool) {
        dividerViews.first { $0.key.mouseAreaID == id }?.value.setForwardedHover(hovered)
    }

    // MARK: Chrome

    func updateChrome(focused: PaneID?, dimsInactive: Bool, animated: Bool) {
        let multiple = paneFrames.count > 1
        let style = context.style
        for pane in paneFrames.keys {
            guard let host = context.hosts[pane] else { continue }
            let isFocused = pane == focused
            host.setChrome(
                showsRing: multiple && isFocused,
                dim: multiple && dimsInactive && !isFocused ? style.inactivePaneDimming : 0,
                ringWidth: style.focusRingWidth,
                showsBorder: style.showsPaneBorder,
                animated: animated
            )
        }
    }

    // MARK: Visibility and hit testing

    /// Panes whose displayed frame intersects the viewport.
    func visiblePanes() -> Set<PaneID> {
        let viewport = bounds
        var result: Set<PaneID> = []
        for (pane, frame) in paneFrames {
            let displayed = frame.rect.offsetBy(dx: -scroll.value, dy: 0)
            let overlap = displayed.intersection(viewport)
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
        KeepAliveBand.panes(displayed: paneFrames.mapValues { $0.rect.offsetBy(dx: -scroll.value, dy: 0) }, viewport: bounds)
    }

    func pane(at localPoint: NSPoint) -> PaneID? {
        let content = CGPoint(x: localPoint.x + scroll.value, y: localPoint.y)
        return geometry.panes.first { $0.value.contains(content) }?.key
    }

    /// Drop target and its highlight rect in local coordinates.
    func dropTarget(at localPoint: NSPoint) -> (target: DropTarget, highlight: CGRect)? {
        let content = CGPoint(x: localPoint.x + scroll.value, y: localPoint.y)
        guard let hit = DropZoneGeometry.target(at: content, screen: screenID, geometry: geometry, style: context.style) else { return nil }
        let target = roomAdjusted(hit)
        guard let rect = DropZoneGeometry.highlightRect(for: target, geometry: geometry, style: context.style) else { return nil }
        return (target, rect.offsetBy(dx: -scroll.value, dy: 0))
    }

    /// Where splitting `pane` along `axis` goes on this screen right now.
    func splitPlacement(splitting pane: PaneID, axis: SplitAxis, removing: PaneID?) -> SplitPlacement {
        SplitRoom.placement(splitting: pane, axis: axis, in: layout, viewport: bounds.size, style: context.style, removing: removing)
    }

    /// An edge drop that cannot split for lack of room becomes a new column
    /// beside the pane's column (columns screen, side edge) or joins the pane.
    private func roomAdjusted(_ target: DropTarget) -> DropTarget {
        guard case let .pane(pane, zone) = target, let axis = zone.splitAxis else { return target }
        switch splitPlacement(splitting: pane, axis: axis, removing: nil) {
        case .split:
            return target
        case .newColumn:
            guard let column = layout.column(containing: pane), let index = layout.columns.firstIndex(of: column) else {
                return .pane(pane, .center)
            }
            let after = zone == .left ? (index > 0 ? layout.columns[index - 1].id : nil) : column.id
            return .newColumn(screen: screenID, after: after)
        case .refused:
            return .pane(pane, .center)
        }
    }

    /// Displayed frame of `pane` in local coordinates.
    func displayedFrame(of pane: PaneID) -> CGRect? {
        paneFrames[pane].map { $0.rect.offsetBy(dx: -scroll.value, dy: 0) }
    }

    /// Releases every hosted pane that is not live elsewhere (screen removed).
    func tearDown() {
        for pane in paneFrames.keys where !context.livePanes.contains(pane) {
            context.release(pane)
        }
        paneFrames.removeAll()
    }
}
