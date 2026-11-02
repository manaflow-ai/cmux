import AppKit
import CmuxNextDesign
import QuartzCore

/// One screen's divider, column-edge and row-edge drags (kept out of `ScreenContentView`, like
/// `ScreenDividers`), emitted as transactional layout intents. The modifier keys held pick how a
/// drag resizes (plans/cmux-next/resize-modifiers.md): every frame derives the values from the
/// drag's start, the pointer and the keys held now, so a key pressed or let go mid-drag switches
/// the mode at once, and a value the new mode no longer sets goes back to its start.
@MainActor
struct DividerDrag {
    let screen: ScreenContentView
    /// Shows the mode hint.
    var toasts: CmuxToastCenter = .shared

    var model: LayoutModel { screen.context.model }

    /// `point` in the geometry space of `kind`: strip space for what
    /// scrolls, view space for a docked column's dividers and edge.
    func contentPoint(fromWindow point: NSPoint, kind: DividerHandleView.Kind) -> CGPoint {
        let local = screen.convert(point, from: nil)
        return screen.scrolls(kind) ? CGPoint(x: local.x - screen.stripShift, y: local.y) : local
    }

    func handle(kind: DividerHandleView.Kind, event: DividerHandleView.DragEvent) {
        switch event {
        case .doubleClick:
            doubleClick(kind)
        case let .began(windowPoint, flags):
            guard var drag = start(kind, at: windowPoint) else { return }
            drag.modifiers = DividerDragModifiers(flags)
            drag.lastWindowPoint = windowPoint
            let raw = contentPoint(fromWindow: windowPoint, kind: kind)
            drag.pressAt = drag.axis == .horizontal ? raw.x : raw.y
            drag.lastRaw = drag.pressAt
            screen.activeDrag = drag
            screen.columnWidths.drop() // a person's drag sets widths on purpose (R3b)
            model.setGestureActive(true)
        case let .moved(windowPoint, flags):
            guard screen.activeDrag != nil else { return }
            screen.activeDrag?.modifiers = DividerDragModifiers(flags)
            screen.activeDrag?.lastWindowPoint = windowPoint
            screen.activeDrag?.sample(contentPoint(fromWindow: windowPoint, kind: kind), at: CACurrentMediaTime())
            screen.resizeGestureMoved()
            apply(at: windowPoint, phase: .changed)
        case let .modifiersChanged(flags):
            let modifiers = DividerDragModifiers(flags)
            guard let drag = screen.activeDrag, modifiers != drag.modifiers else { return }
            screen.activeDrag?.modifiers = modifiers
            // A press that has not moved yet stays a click: nothing to re-apply.
            guard drag.pointer != nil else { return }
            apply(at: drag.lastWindowPoint, phase: .changed)
        case .cancelled:
            cancel(redraw: true)
        case let .ended(windowPoint, flags):
            // A press and release with no move between them is a click, not a resize: saving
            // the ratio the divider is drawn at (clamped by a narrow window) would replace the
            // stored one.
            guard let drag = screen.activeDrag, drag.pointer != nil else { return cancel() }
            screen.activeDrag?.modifiers = DividerDragModifiers(flags)
            if case .split = kind {
                // The layout this release makes springs on from the pointer's velocity.
                screen.releasedDivider = (kind, drag.releaseVelocity(at: CACurrentMediaTime()), CACurrentMediaTime())
            }
            apply(at: windowPoint, phase: .ended)
            screen.activeDrag?.hintToast?.dismiss()
            screen.activeDrag = nil
            model.setGestureActive(false)
            screen.resizeGestureReleased()
        }
    }

    /// Ends the drag with nothing of it kept: Escape, a handle that left the tree, a click. Its
    /// values go back to the start (`LayoutModel.cancelGesture`) and gesture mode ends. `redraw`
    /// (Escape) lays a row drag's preview out again at once; a handle that left the tree is mid-sync,
    /// which lays out anyway.
    func cancel(redraw: Bool = false) {
        guard let drag = screen.activeDrag else { return }
        drag.hintToast?.dismiss()
        screen.activeDrag = nil
        if screen.rowDragPreview != nil {
            screen.rowDragPreview = nil
            if redraw { screen.reconcile(animated: false) }
        }
        model.cancelGesture(drag.transaction)
        model.setGestureActive(false)
        screen.resizeGestureReleased()
    }

    private func doubleClick(_ kind: DividerHandleView.Kind) {
        switch kind {
        case let .split(id):
            model.equalizeSplit(id)
        case let .columnEdge(id):
            guard let column = screen.layout.columns.first(where: { $0.id == id }) else { return }
            model.setColumnWidth(id, width: ColumnWidthPreset.next(after: column.width).rawValue, transaction: .make(), phase: .ended)
        case .rowEdge:
            // Equalize Rows (Z3) is a later surfaces step.
            return
        }
    }

    /// Writes this frame's values. A split or column the drag set before and does not set now goes
    /// back to its start first. The model's observation lays each value out (one sync per turn: events that arrive
    /// together show once); a still pointer asks for no frames.
    func apply(at windowPoint: NSPoint, phase: LayoutGesturePhase) {
        guard var drag = screen.activeDrag else { return }
        let point = drag.effective(contentPoint(fromWindow: windowPoint, kind: drag.kind))
        let targets: [DividerDragValue]
        switch drag.kind {
        case let .split(id):
            targets = splitTargets(id, drag: &drag, point: point, phase: phase)
        case let .columnEdge(id):
            targets = columnTargets(id, drag: drag, point: point)
        case let .rowEdge(column, upper):
            screen.activeDrag = drag
            return applyRowEdge(column, upper: upper, drag: drag, windowPoint: windowPoint, phase: phase)
        }
        let keys = Set(targets.map(\.key))
        let restored = drag.touched.subtracting(keys)
        drag.touched = keys
        drag = phase == .ended ? drag : showingHint(drag)
        screen.activeDrag = drag
        model.restoreGestureValues(restored, transaction: drag.transaction)
        for target in targets {
            switch target {
            case let .ratio(split, ratio): model.setSplitRatio(split, ratio: ratio, transaction: drag.transaction, phase: phase)
            case let .width(column, width): model.setColumnWidth(column, width: width, transaction: drag.transaction, phase: phase)
            }
        }
    }

    private func splitTargets(_ id: SplitID, drag: inout DividerDragState, point: CGPoint, phase: LayoutGesturePhase) -> [DividerDragValue] {
        let style = screen.context.style
        if drag.modifiers.push, let push = drag.push {
            return push.targets(delta: (drag.axis == .horizontal ? point.x : point.y) - drag.pressAt)
        }
        // A fling that would carry the divider onto a snap within the spring's reach lands there
        // (not with Control or Shift: those land where the pointer put them).
        let flings = phase == .ended && screen.context.animatesPaneLayout && !drag.modifiers.fine && !drag.modifiers.snap
        let reach = flings ? (screen.releasedDivider?.velocity ?? 0) * CGFloat(Motion.panes.dividerReleaseProjection) : 0
        let projected = drag.axis == .horizontal ? CGPoint(x: point.x + reach, y: point.y) : CGPoint(x: point.x, y: point.y + reach)
        var probe = drag
        let flung = reach != 0 ? probe.splitRatio(at: projected, style: style, phase: phase) : nil
        let ratio = flung.flatMap { drag.snaps.contains($0) ? $0 : nil } ?? drag.splitRatio(at: point, style: style, phase: phase)
        var targets = [DividerDragValue.ratio(id, ratio)]
        if drag.modifiers.all, let node = drag.tree?.node(for: id) {
            let even = EvenSplitRatios.changes(equalizing: node.a, axis: node.axis) + EvenSplitRatios.changes(equalizing: node.b, axis: node.axis)
            targets += even.map { .ratio($0.split, $0.ratio) }
        }
        return targets
    }

    private func columnTargets(_ id: ColumnID, drag: DividerDragState, point: CGPoint) -> [DividerDragValue] {
        // Strip widths are shares of the strip's viewport; a side dock's
        // width is a share of the whole view's width, a top or bottom
        // dock's height a share of its height (same formula).
        let extent: CGFloat
        switch drag.dockEdge {
        case .right?: extent = max(drag.container.maxX - (point.x - drag.grabOffset), drag.minimumA)
        case .top?: extent = max(point.y - drag.grabOffset - drag.container.minY, drag.minimumA)
        case .bottom?: extent = max(drag.container.maxY - (point.y - drag.grabOffset), drag.minimumA)
        case .left?, nil: extent = max(point.x - drag.grabOffset - drag.container.minX, drag.minimumA)
        }
        let viewport = switch drag.dockEdge {
        case nil: screen.geometry.stripWidth
        case .top?, .bottom?: screen.bounds.height
        case .left?, .right?: screen.bounds.width
        }
        let gap = screen.context.style.stripGap
        var fraction = ColumnStripGeometry.fraction(forPixelWidth: extent, viewportWidth: viewport, gap: gap)
        if drag.modifiers.snap, !drag.modifiers.fine {
            // Shift: the nearest preset the column fits at (thirds, half, full).
            let fits = ColumnWidthPreset.allCases.filter {
                ColumnStripGeometry.pixelWidth(fraction: $0.rawValue, viewportWidth: viewport, gap: gap) >= drag.minimumA
            }
            if let nearest = fits.min(by: { abs($0.rawValue - fraction) < abs($1.rawValue - fraction) }) { fraction = nearest.rawValue }
        }
        guard drag.dockEdge == nil, let strip = drag.strip else { return [.width(id, fraction)] }
        if drag.modifiers.all { return strip.uniform(fraction) }
        if drag.modifiers.push { return strip.trading(id, to: fraction) }
        return [.width(id, fraction)]
    }

    private func applyRowEdge(_ column: ColumnID, upper: RowID, drag: DividerDragState, windowPoint: NSPoint, phase: LayoutGesturePhase) {
        guard let start = drag.rows else { return }
        let pointer = screen.convert(windowPoint, from: nil).y + screen.rowOffset(of: drag.kind) - drag.grabOffset
        let heights = RowResize.heights(start.rows, stack: start.stack, upper: upper, pointerY: pointer,
                                        minimums: start.minimums, fits: !screen.context.style.rowsEnabled)
        screen.rowDragPreview = (column, heights)
        screen.reconcile(animated: false)
        if phase == .ended {
            // One intent on release; the preview stays until the next
            // layout carries it.
            model.setRowHeights(column, heights: heights, fit: heights.reduce(0) { $0 + $1.height } == 1000)
        }
    }
}
