import AppKit
import CmuxNextDesign

/// Renders one screen: a split tree, or a horizontally scrolling strip of
/// columns. Pane and divider frames are springs in content space; the
/// displayed frame subtracts the scroll offset.
final class ScreenContentView: NSView {
    let screenID: ScreenID
    private let context: LayoutViewContext

    private(set) var layout: ScreenLayout
    private(set) var geometry: ScreenGeometry
    private var paneFrames: [PaneID: AnimatedFrame] = [:]
    private var removingPanes: [PaneID: AnimatedFrame] = [:]
    private var dividerViews: [DividerHandleView.Kind: DividerHandleView] = [:]
    private var dividerFrames: [DividerHandleView.Kind: AnimatedFrame] = [:]

    private(set) var scroll = SpringValue(0)
    /// Unbanded offset accumulated during a trackpad gesture.
    private var rawScroll: CGFloat = 0
    private(set) var isUserScrolling = false
    private var scrollSamples: [(time: TimeInterval, delta: CGFloat)] = []
    private var reportScrollOnSettle = false

    private var activeDrag: ActiveDrag?

    private struct ActiveDrag {
        var kind: DividerHandleView.Kind
        var transaction: LayoutTransactionID
        var grabOffset: CGFloat
        var container: CGRect
        var axis: SplitAxis
    }

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
    @discardableResult
    func update(layout: ScreenLayout, animated: Bool) -> Bool {
        self.layout = layout
        return reconcile(animated: animated)
    }

    @discardableResult
    private func reconcile(animated: Bool) -> Bool {
        let previous = geometry
        geometry = ScreenGeometry.compute(layout, viewport: bounds.size, style: context.style, scale: scale)
        let animate = animated && !context.reduceMotion && bounds.width > 0
        var needsFrames = false

        // Panes.
        for (pane, target) in geometry.panes {
            if var existing = paneFrames[pane] {
                existing.setTarget(target, alpha: 1)
                if !animate { existing.snap() }
                paneFrames[pane] = existing
            } else {
                let host = context.host(for: pane)
                if host.superview !== self {
                    addSubview(host, positioned: .below, relativeTo: firstDividerView)
                }
                var frame: AnimatedFrame
                if let removing = removingPanes.removeValue(forKey: pane) {
                    frame = removing
                } else if animate {
                    frame = AnimatedFrame(insertionStart(for: pane, target: target, previous: previous), alpha: 0)
                } else {
                    frame = AnimatedFrame(target)
                }
                frame.setTarget(target, alpha: 1)
                if !animate { frame.snap() }
                paneFrames[pane] = frame
            }
        }
        for pane in paneFrames.keys where geometry.panes[pane] == nil {
            guard var frame = paneFrames.removeValue(forKey: pane) else { continue }
            if context.livePanes.contains(pane) {
                // Moved to another screen; that screen owns the host now.
                continue
            }
            if animate {
                let rect = frame.rect
                frame.setTarget(rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04), alpha: 0)
                removingPanes[pane] = frame
            } else {
                context.release(pane)
            }
        }
        if !animate {
            for pane in removingPanes.keys { context.release(pane) }
            removingPanes.removeAll()
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
            if var frame = dividerFrames[kind] {
                frame.setTarget(target.rect, alpha: 1)
                if !animate { frame.snap() }
                dividerFrames[kind] = frame
            } else {
                var frame = AnimatedFrame(target.rect, alpha: animate ? 0 : 1)
                frame.setTarget(target.rect, alpha: 1)
                dividerFrames[kind] = frame
            }
        }
        for kind in dividerViews.keys where targets[kind] == nil {
            dividerViews.removeValue(forKey: kind)?.removeFromSuperview()
            dividerFrames[kind] = nil
        }

        // Scroll.
        let clamped = ColumnStripGeometry.clamp(scroll.target, contentWidth: geometry.contentWidth, viewportWidth: bounds.width)
        if clamped != scroll.target && !isUserScrolling {
            scroll.target = clamped
            if !animate { scroll.snap() }
        }
        if !geometry.isColumns {
            scroll = SpringValue(0)
        }

        applyPresentation()
        if animate { needsFrames = hasMotion }
        return needsFrames
    }

    private var firstDividerView: NSView? {
        subviews.first { $0 is DividerHandleView }
    }

    /// New panes grow from slightly inside their target; panes of a new
    /// column slide in from the trailing side, like niri.
    private func insertionStart(for pane: PaneID, target: CGRect, previous: ScreenGeometry) -> CGRect {
        if let column = layout.column(containing: pane), previous.columns[column.id] == nil, !previous.columns.isEmpty {
            return target.offsetBy(dx: min(80, target.width * 0.2), dy: 0)
        }
        return target.insetBy(dx: target.width * 0.04, dy: target.height * 0.04)
    }

    // MARK: Animation

    private var hasMotion: Bool {
        if !removingPanes.isEmpty { return true }
        if !isUserScrolling && (scroll.value != scroll.target || scroll.velocity != 0) { return true }
        return paneFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
            || dividerFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
    }

    /// Advances springs by `dt`. Returns true while anything still moves.
    func step(_ dt: Double) -> Bool {
        var moving = false
        for key in Array(paneFrames.keys) {
            if paneFrames[key]!.advance(dt, parameters: .layout) { moving = true }
        }
        for key in Array(dividerFrames.keys) {
            if dividerFrames[key]!.advance(dt, parameters: .layout) { moving = true }
        }
        for key in Array(removingPanes.keys) {
            if removingPanes[key]!.advance(dt, parameters: .layout) {
                moving = true
            } else {
                removingPanes[key] = nil
                context.release(key)
            }
        }
        if !isUserScrolling {
            if scroll.advance(dt, parameters: .scroll, epsilon: 0.25) {
                moving = true
            } else if reportScrollOnSettle {
                reportScrollOnSettle = false
                reportLeadingColumn()
            }
        }
        applyPresentation()
        return moving
    }

    private func applyPresentation() {
        let dx = -scroll.value
        for (pane, frame) in paneFrames {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            host.frame = frame.rect.offsetBy(dx: dx, dy: 0)
            host.alphaValue = frame.alpha.value
        }
        for (pane, frame) in removingPanes {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            host.frame = frame.rect.offsetBy(dx: dx, dy: 0)
            host.alphaValue = frame.alpha.value
        }
        for (kind, frame) in dividerFrames {
            guard let view = dividerViews[kind] else { continue }
            view.frame = frame.rect.offsetBy(dx: dx, dy: 0)
            view.alphaValue = frame.alpha.value
        }
    }

    // MARK: Chrome

    func updateChrome(focused: PaneID?, dimsInactive: Bool) {
        let multiple = paneFrames.count > 1
        let style = context.style
        for pane in paneFrames.keys {
            guard let host = context.hosts[pane] else { continue }
            let isFocused = pane == focused
            host.setChrome(
                showsRing: multiple && isFocused,
                dim: multiple && dimsInactive && !isFocused ? style.inactivePaneDimming : 0,
                ringWidth: style.focusRingWidth
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

    func pane(at localPoint: NSPoint) -> PaneID? {
        let content = CGPoint(x: localPoint.x + scroll.value, y: localPoint.y)
        return geometry.panes.first { $0.value.contains(content) }?.key
    }

    /// Drop target and its highlight rect in local coordinates.
    func dropTarget(at localPoint: NSPoint) -> (target: DropTarget, highlight: CGRect)? {
        let content = CGPoint(x: localPoint.x + scroll.value, y: localPoint.y)
        guard let target = DropZoneGeometry.target(at: content, screen: screenID, geometry: geometry, style: context.style),
              let rect = DropZoneGeometry.highlightRect(for: target, geometry: geometry, style: context.style) else { return nil }
        return (target, rect.offsetBy(dx: -scroll.value, dy: 0))
    }

    /// Displayed frame of `pane` in local coordinates.
    func displayedFrame(of pane: PaneID) -> CGRect? {
        paneFrames[pane].map { $0.rect.offsetBy(dx: -scroll.value, dy: 0) }
    }

    // MARK: Scrolling

    /// Scrolls so `pane`'s column is visible per `mode`. Returns true if frames are needed.
    @discardableResult
    func reveal(_ pane: PaneID, mode: ColumnRevealMode, animated: Bool) -> Bool {
        guard geometry.isColumns, let column = layout.column(containing: pane), let frame = geometry.columns[column.id] else { return false }
        let target = ColumnStripGeometry.revealOffset(
            for: frame,
            current: scroll.target,
            viewportWidth: bounds.width,
            contentWidth: geometry.contentWidth,
            gap: context.style.columnGap,
            mode: mode
        )
        guard target != scroll.target else { return false }
        scroll.target = target
        reportScrollOnSettle = true
        if !animated || context.reduceMotion {
            scroll.snap()
            applyPresentation()
            reportScrollOnSettle = false
            reportLeadingColumn()
            return false
        }
        return true
    }

    var acceptsHorizontalScroll: Bool { geometry.isColumns && geometry.maxOffset > 0.5 }

    func beginUserScroll() {
        isUserScrolling = true
        scroll.velocity = 0
        rawScroll = scroll.value
        scrollSamples.removeAll()
    }

    func userScroll(deltaX: CGFloat, timestamp: TimeInterval) {
        rawScroll -= deltaX
        scroll.value = ColumnStripGeometry.rubberBand(rawScroll, contentWidth: geometry.contentWidth, viewportWidth: bounds.width)
        scroll.target = scroll.value
        scrollSamples.append((timestamp, -deltaX))
        scrollSamples.removeAll { timestamp - $0.time > 0.1 }
        applyPresentation()
    }

    /// Ends a trackpad gesture: projects the fling and springs to a column edge.
    func endUserScroll(timestamp: TimeInterval) {
        isUserScrolling = false
        let recent = scrollSamples.filter { timestamp - $0.time <= 0.1 }
        var velocity: CGFloat = 0
        if let first = recent.first, recent.count > 1 {
            let dt = max(timestamp - first.time, 1.0 / 120.0)
            velocity = recent.reduce(0) { $0 + $1.delta } / CGFloat(dt)
        }
        scrollSamples.removeAll()
        let target = ColumnStripGeometry.snapTarget(releaseOffset: scroll.value, velocity: velocity, snaps: geometry.snapOffsets)
        scroll.target = target
        scroll.velocity = velocity
        reportScrollOnSettle = true
        if context.reduceMotion {
            scroll.snap()
            applyPresentation()
        }
    }

    /// One mouse wheel notch: move to the adjacent snap point.
    func discreteScroll(direction: Int) {
        scroll.target = ColumnStripGeometry.adjacentSnap(from: scroll.target, direction: direction, snaps: geometry.snapOffsets)
        reportScrollOnSettle = true
        if context.reduceMotion {
            scroll.snap()
            applyPresentation()
        }
    }

    private func reportLeadingColumn() {
        guard geometry.isColumns,
              let index = ColumnStripGeometry.leadingColumnIndex(frames: geometry.orderedColumnFrames, offset: scroll.value, gap: context.style.columnGap)
        else { return }
        context.model.reportScroll(screen: screenID, leadingColumn: geometry.columnOrder[index])
    }

    // MARK: Divider drags

    private func contentPoint(fromWindow point: NSPoint) -> CGPoint {
        let local = convert(point, from: nil)
        return CGPoint(x: local.x + scroll.value, y: local.y)
    }

    private func handleDrag(kind: DividerHandleView.Kind, event: DividerHandleView.DragEvent) {
        let model = context.model
        switch event {
        case .doubleClick:
            switch kind {
            case let .split(id):
                model.equalizeSplit(id)
            case let .columnEdge(id):
                guard let column = layout.columns.first(where: { $0.id == id }) else { return }
                model.setColumnWidth(id, width: ColumnWidthPreset.next(after: column.width).rawValue, transaction: .make(), phase: .ended)
            }
        case let .began(windowPoint):
            let point = contentPoint(fromWindow: windowPoint)
            switch kind {
            case let .split(id):
                guard let divider = geometry.dividers.first(where: { $0.id == id }) else { return }
                let pointer = divider.axis == .horizontal ? point.x : point.y
                let start = divider.axis == .horizontal ? divider.frame.minX : divider.frame.minY
                activeDrag = ActiveDrag(kind: kind, transaction: .make(), grabOffset: pointer - start, container: divider.container, axis: divider.axis)
            case let .columnEdge(id):
                guard let frame = geometry.columns[id] else { return }
                activeDrag = ActiveDrag(kind: kind, transaction: .make(), grabOffset: point.x - frame.maxX, container: frame, axis: .horizontal)
            }
            model.setGestureActive(true)
            context.requestFrames()
        case let .moved(windowPoint):
            applyDrag(at: windowPoint, phase: .changed)
            context.requestFrames()
        case let .ended(windowPoint):
            applyDrag(at: windowPoint, phase: .ended)
            activeDrag = nil
            model.setGestureActive(false)
        }
    }

    private func applyDrag(at windowPoint: NSPoint, phase: LayoutGesturePhase) {
        guard let drag = activeDrag else { return }
        let point = contentPoint(fromWindow: windowPoint)
        let style = context.style
        switch drag.kind {
        case let .split(id):
            let pointer = drag.axis == .horizontal ? point.x : point.y
            let ratio = SplitGeometry.ratio(forPointer: pointer, grabOffset: drag.grabOffset, container: drag.container, axis: drag.axis, style: style)
            context.model.setSplitRatio(id, ratio: ratio, transaction: drag.transaction, phase: phase)
        case let .columnEdge(id):
            let width = point.x - drag.grabOffset - drag.container.minX
            let fraction = ColumnStripGeometry.fraction(forPixelWidth: width, viewportWidth: bounds.width, gap: style.columnGap)
            context.model.setColumnWidth(id, width: fraction, transaction: drag.transaction, phase: phase)
        }
    }

    /// Releases every hosted pane that is not live elsewhere (screen removed).
    func tearDown() {
        for pane in Array(paneFrames.keys) + Array(removingPanes.keys) where !context.livePanes.contains(pane) {
            context.release(pane)
        }
        paneFrames.removeAll()
        removingPanes.removeAll()
    }
}
