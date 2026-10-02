import AppKit

/// Divider and column-edge drags, emitted as transactional layout intents.
extension ScreenContentView {
    struct ActiveDrag {
        var kind: DividerHandleView.Kind
        var transaction: LayoutTransactionID
        var grabOffset: CGFloat
        var container: CGRect
        var axis: SplitAxis
        /// Minimum extents of the two sides (split) or of the column.
        var minimumA: CGFloat = 0
        var minimumB: CGFloat = 0
        /// A sticky column's handle: on the right edge it grows leftward.
        var stickyEdge: StickyEdge?
    }

    /// `point` in the geometry space of `kind`: strip space for what
    /// scrolls, view space for a sticky column's dividers and edge.
    func contentPoint(fromWindow point: NSPoint, kind: DividerHandleView.Kind) -> CGPoint {
        let local = convert(point, from: nil)
        return scrolls(kind) ? CGPoint(x: local.x - stripShift, y: local.y) : local
    }

    func handleDrag(kind: DividerHandleView.Kind, event: DividerHandleView.DragEvent) {
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
            let point = contentPoint(fromWindow: windowPoint, kind: kind)
            switch kind {
            case let .split(id):
                guard let divider = geometry.dividers.first(where: { $0.id == id }) else { return }
                let pointer = divider.axis == .horizontal ? point.x : point.y
                let start = divider.axis == .horizontal ? divider.frame.minX : divider.frame.minY
                activeDrag = ActiveDrag(kind: kind, transaction: .make(), grabOffset: pointer - start, container: divider.container,
                                        axis: divider.axis, minimumA: divider.minimumA, minimumB: divider.minimumB)
            case let .columnEdge(id):
                guard let frame = geometry.columns[id] else { return }
                let minimum = layout.columns.first { $0.id == id }.map { SplitGeometry.minimumSize(of: $0.root, style: context.style).width } ?? 0
                let edge = geometry.columnEdges.first { $0.column == id }?.stickyEdge
                let grab = edge == .right ? point.x - frame.minX : point.x - frame.maxX
                activeDrag = ActiveDrag(kind: kind, transaction: .make(), grabOffset: grab, container: frame,
                                        axis: .horizontal, minimumA: minimum, stickyEdge: edge)
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

    func applyDrag(at windowPoint: NSPoint, phase: LayoutGesturePhase) {
        guard let drag = activeDrag else { return }
        let point = contentPoint(fromWindow: windowPoint, kind: drag.kind)
        let style = context.style
        switch drag.kind {
        case let .split(id):
            let pointer = drag.axis == .horizontal ? point.x : point.y
            let ratio = SplitGeometry.ratio(forPointer: pointer, grabOffset: drag.grabOffset, container: drag.container, axis: drag.axis,
                                            style: style, minimumA: drag.minimumA, minimumB: drag.minimumB)
            context.model.setSplitRatio(id, ratio: ratio, transaction: drag.transaction, phase: phase)
        case let .columnEdge(id):
            // Strip widths are shares of the strip's viewport; a sticky
            // column's width is a share of the whole view.
            let width: CGFloat
            switch drag.stickyEdge {
            case .right?: width = max(drag.container.maxX - (point.x - drag.grabOffset), drag.minimumA)
            case .left?, .top?, .bottom?, nil: width = max(point.x - drag.grabOffset - drag.container.minX, drag.minimumA)
            }
            let viewport = drag.stickyEdge == nil ? geometry.stripWidth : bounds.width
            let fraction = ColumnStripGeometry.fraction(forPixelWidth: width, viewportWidth: viewport, gap: style.stripGap)
            context.model.setColumnWidth(id, width: fraction, transaction: drag.transaction, phase: phase)
        }
    }
}
