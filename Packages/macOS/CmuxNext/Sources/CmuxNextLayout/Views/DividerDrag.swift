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
            catchShown(kind, at: windowPoint)
        case let .moved(windowPoint, flags):
            guard screen.activeDrag != nil else { return }
            screen.activeDrag?.modifiers = DividerDragModifiers(flags)
            screen.activeDrag?.lastWindowPoint = windowPoint
            let point = contentPoint(fromWindow: windowPoint, kind: kind)
            screen.activeDrag?.sample(point, at: CACurrentMediaTime())
            screen.resizeGestureMoved()
            // Control's trail follows every event, with the keys held at it; the frame tick writes the newest point.
            _ = screen.activeDrag?.effective(point)
            waitForFrame()
        case let .modifiersChanged(flags):
            let modifiers = DividerDragModifiers(flags)
            guard let drag = screen.activeDrag, modifiers != drag.modifiers else { return }
            screen.activeDrag?.modifiers = modifiers
            // A press that has not moved yet stays a click: nothing to re-apply.
            guard drag.pointer != nil else { return }
            waitForFrame()
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
                screen.releasedDivider = (kind, drag.releaseVelocity(at: CACurrentMediaTime()), CACurrentMediaTime(), drag.sharedEdges)
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
        // A press that caught a springing value: the release it replaced lands as it would have.
        if let replaced = drag.replaced { set(replaced, transaction: .make(), phase: .ended) }
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

    /// A move or a key change only keeps the pointer and keys for the window's next frame tick, and asks for it: that
    /// tick writes the newest ones once (``applyWaiting()``), so a burst of events in one display frame costs one model
    /// write and one layout pass (Chrome aligns input to the begin-frame). The release (`ended`) still applies in its
    /// own turn, at its own point; a cancel drops what waits.
    private func waitForFrame() {
        screen.activeDrag?.waiting = true
        screen.activeDrag?.ticksLeft = ScreenContentView.panTickTail
        screen.context.requestFrames()
    }

    /// The frame tick (`LayoutFrameInput`): writes the pointer and keys the drag's events left waiting, once.
    func applyWaiting() { // perf-hot: 4ms motion-frame
        guard let drag = screen.activeDrag, drag.waiting else { return }
        screen.activeDrag?.waiting = false
        apply(at: drag.lastWindowPoint, phase: .changed)
    }

    /// Writes this frame's values. A split or column the drag set before and does not set now goes
    /// back to its start first. The model's observation lays each value out (one sync per turn: events that arrive
    /// together show once), or in the frame tick its own sync does (`LayoutFrameInput`); a still pointer asks for no
    /// frames.
    func apply(at windowPoint: NSPoint, phase: LayoutGesturePhase) {
        guard var drag = screen.activeDrag else { return }
        let point = drag.effective(contentPoint(fromWindow: windowPoint, kind: drag.kind))
        // A line caught in a clamp (rule D) never shows behind the pointer (`SharedEdgeClamp.follow`).
        if let clamp = drag.clampHold, !clamp.follow((drag.axis == .horizontal ? point.x : point.y) - drag.grabOffset, on: screen) {
            drag.clampHold = nil
        }
        var targets: [DividerDragValue]
        switch drag.kind {
        case let .split(id):
            targets = splitTargets(id, drag: &drag, point: point, phase: phase)
        case let .columnEdge(id):
            targets = columnTargets(id, drag: &drag, point: point, phase: phase)
        case let .rowEdge(column, upper):
            screen.activeDrag = drag
            return applyRowEdge(column, upper: upper, drag: drag, windowPoint: windowPoint, phase: phase)
        }
        var keys = Set(targets.map(\.key))
        // The caught value is this drag's start for its key (rule C): a mode that stops setting it puts it back there.
        if let caught = drag.caughtValue, drag.touched.contains(caught.key), !keys.contains(caught.key) {
            (targets, keys) = (targets + [caught], keys.union([caught.key]))
        }
        let restored = drag.touched.subtracting(keys)
        drag.touched = keys
        drag = phase == .ended ? drag : showingHint(drag)
        screen.activeDrag = drag
        model.restoreGestureValues(restored, transaction: drag.transaction)
        // The release's values are one change, all or nothing (`EndedValues`): what the app cannot send takes the drag back.
        if phase == .ended {
            EndedValues(targets, transaction: drag.transaction).send(in: model)
            return
        }
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
            // A push lands where the pointer is (Option-Shift too, resize-modifiers.md): no Shift landing to keep.
            drag.snapped = nil
            return push.targets(delta: (drag.axis == .horizontal ? point.x : point.y) - drag.pressAt)
        }
        // Where the pointer is, a fling's release too; Shift's release on the nearest snap, where its spring carries it.
        let ratio = drag.splitRatio(at: point, style: style, phase: phase)
        var targets = [DividerDragValue.ratio(id, ratio)]
        if drag.modifiers.all, let node = drag.tree?.node(for: id) {
            let even = EvenSplitRatios.changes(equalizing: node.a, axis: node.axis) + EvenSplitRatios.changes(equalizing: node.b, axis: node.axis)
            targets += even.map { .ratio($0.split, $0.ratio) }
        }
        return targets
    }

    private func columnTargets(_ id: ColumnID, drag: inout DividerDragState, point: CGPoint, phase: LayoutGesturePhase) -> [DividerDragValue] {
        // Strip widths are shares of the strip's viewport; a side dock's
        // width is a share of the whole view's width, a top or bottom
        // dock's height a share of its height (same formula).
        let extent: CGFloat
        switch drag.dockEdge {
        case .right?: extent = max(drag.container.maxX - (point.x - drag.grabOffset), drag.minimumA)
        case .top?: extent = max(point.y - drag.grabOffset - drag.container.minY, drag.minimumA)
        case .bottom?: extent = max(drag.container.maxY - (point.y - drag.grabOffset), drag.minimumA)
        case .left?, nil:
            // Command where no uniform width holds the edge: every width stays as it is (the edge at its limit).
            let uniform = uniformTarget(id, drag: drag, point: point)
            if uniform == .keep, drag.modifiers.all, !drag.landsOnSnap, let strip = drag.strip {
                return strip.columns.compactMap { column in
                    screen.geometry.columns[column.id].map { .width(column.id, strip.fraction($0.width)) }
                }
            }
            if case let .width(width)? = uniform { extent = max(width, drag.minimumA) } else {
                extent = max(point.x - drag.grabOffset - drag.container.minX, drag.minimumA)
            }
        }
        let viewport = switch drag.dockEdge {
        case nil: screen.geometry.stripWidth
        case .top?, .bottom?: screen.bounds.height
        case .left?, .right?: screen.bounds.width
        }
        let gap = screen.context.style.stripGap
        var fraction = ColumnStripGeometry.fraction(forPixelWidth: extent, viewportWidth: viewport, gap: gap)
        if drag.landsOnSnap {
            // Shift: the release lands on the nearest preset the column fits at (thirds, half, full); the drag follows the pointer.
            let fits = ColumnWidthPreset.allCases.filter {
                ColumnStripGeometry.pixelWidth(fraction: $0.rawValue, viewportWidth: viewport, gap: gap) >= drag.minimumA
            }
            let nearest = fits.min(by: { abs($0.rawValue - fraction) < abs($1.rawValue - fraction) })
            if let landing = drag.land(on: nearest?.rawValue, phase: phase) { fraction = landing }
        } else {
            drag.snapped = nil
        }
        guard drag.dockEdge == nil, let strip = drag.strip else { return [.width(id, fraction)] }
        if drag.modifiers.all { return strip.uniform(fraction) }
        if drag.modifiers.push { return strip.trading(id, to: fraction) }
        return [.width(id, fraction)]
    }

    /// Command on a strip column's edge: the width every column takes so that the edge shows where the pointer puts it,
    /// with the camera the anchored sync will show (`UniformEdge`), or `.keep` where no uniform width holds the edge. The
    /// pointer is measured on screen (strip space less the camera now), not in the strip at the camera the last move left:
    /// the anchor moves the camera on each move. Nil for every other drag.
    private func uniformTarget(_ id: ColumnID, drag: DividerDragState, point: CGPoint) -> UniformEdge.Target? {
        guard drag.modifiers.all, drag.dockEdge == nil, let strip = drag.strip, let index = strip.columns.firstIndex(where: { $0.id == id }),
              let frame = screen.geometry.columns[id] else { return nil }
        let widths = strip.columns.compactMap { screen.geometry.columns[$0.id]?.width }
        guard widths.count == strip.columns.count else { return nil }
        let geometry = screen.geometry
        return UniformEdge(widths: widths, index: index, left: frame.minX, content: geometry.contentWidth, viewport: geometry.stripWidth,
                           camera: screen.scroll.target, shown: screen.scroll.value)
            .target(restingEdgeAt: point.x - drag.grabOffset - screen.scroll.value)
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
