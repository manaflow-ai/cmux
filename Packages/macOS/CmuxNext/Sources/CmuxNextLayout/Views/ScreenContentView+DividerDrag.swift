import AppKit

/// Divider and column-edge drags, emitted as transactional layout intents.
extension ScreenContentView {
    /// `point` in the geometry space of `kind`: strip space for what
    /// scrolls, view space for a docked column's dividers and edge.
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
            case .rowEdge:
                // Equalize Rows (Z3) is a later surfaces step.
                return
            }
        case let .began(windowPoint):
            let point = contentPoint(fromWindow: windowPoint, kind: kind)
            switch kind {
            case let .split(id):
                guard let divider = geometry.dividers.first(where: { $0.id == id }) else { return }
                let pointer = divider.axis == .horizontal ? point.x : point.y
                let start = divider.axis == .horizontal ? divider.frame.minX : divider.frame.minY
                activeDrag = DividerDragState(kind: kind, transaction: .make(), grabOffset: pointer - start, container: divider.container,
                                        axis: divider.axis, minimumA: divider.minimumA, minimumB: divider.minimumB)
            case let .columnEdge(id):
                guard let frame = geometry.columns[id] else { return }
                let size = layout.columns.first { $0.id == id }.map { SplitGeometry.minimumSize(of: $0.root, style: context.style) } ?? .zero
                let edge = geometry.columnEdges.first { $0.column == id }?.dockEdge
                let grab: CGFloat = switch edge {
                case .right?: point.x - frame.minX
                case .top?: point.y - frame.maxY
                case .bottom?: point.y - frame.minY
                case .left?, nil: point.x - frame.maxX
                }
                let band = edge?.isBand == true
                activeDrag = DividerDragState(kind: kind, transaction: .make(), grabOffset: grab, container: frame,
                                        axis: band ? .vertical : .horizontal, minimumA: band ? size.height : size.width, dockEdge: edge)
            case let .rowEdge(columnID, upper):
                guard let column = layout.columns.first(where: { $0.id == columnID }), let stack = baseGeometry.rowStacks[columnID],
                      let upperFrame = stack.frame(of: upper) else { return }
                let y = local(windowPoint).y + rowOffset(of: kind)
                let minimums = Dictionary(uniqueKeysWithValues: column.rows.map {
                    ($0.id, SplitGeometry.minimumSize(of: $0.root, style: context.style).height)
                })
                activeDrag = DividerDragState(kind: kind, transaction: .make(), grabOffset: y - upperFrame.maxY, container: stack.frame,
                                        axis: .vertical, rows: RowDragStart(rows: column.rows, stack: stack, minimums: minimums))
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

    /// Ends a drag whose handle left the tree: no release will come. It is
    /// cancelled (`LayoutModel.cancelGesture`) and gesture mode ends.
    func endDrag() {
        guard let drag = activeDrag else { return }
        activeDrag = nil
        rowDragPreview = nil
        context.model.cancelGesture(drag.transaction)
        context.model.setGestureActive(false)
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
            case nil: geometry.stripWidth
            case .top?, .bottom?: bounds.height
            case .left?, .right?: bounds.width
            }
            let fraction = ColumnStripGeometry.fraction(forPixelWidth: extent, viewportWidth: viewport, gap: style.stripGap)
            context.model.setColumnWidth(id, width: fraction, transaction: drag.transaction, phase: phase)
        case let .rowEdge(column, upper):
            guard let start = drag.rows else { return }
            let pointer = local(windowPoint).y + rowOffset(of: drag.kind) - drag.grabOffset
            let heights = RowResize.heights(start.rows, stack: start.stack, upper: upper, pointerY: pointer,
                                            minimums: start.minimums, fits: !context.style.rowsEnabled)
            rowDragPreview = (column, heights)
            reconcile(animated: false)
            if phase == .ended {
                // One intent on release; the preview stays until the next
                // layout carries it.
                context.model.setRowHeights(column, heights: heights, fit: heights.reduce(0) { $0 + $1.height } == 1000)
            }
        }
    }

    /// `windowPoint` in this view's coordinates.
    private func local(_ windowPoint: NSPoint) -> NSPoint { convert(windowPoint, from: nil) }
}
