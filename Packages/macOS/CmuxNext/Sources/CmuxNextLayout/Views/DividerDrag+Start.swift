import AppKit

/// What a divider, column-edge or row-edge drag records on its press: the layout it starts from,
/// which every frame (and every modifier mode) derives its values from.
extension DividerDrag {
    func start(_ kind: DividerHandleView.Kind, at windowPoint: NSPoint) -> DividerDragState? {
        let point = contentPoint(fromWindow: windowPoint, kind: kind)
        let style = screen.context.style
        let layout = screen.layout
        switch kind {
        case let .split(id):
            guard let divider = screen.geometry.dividers.first(where: { $0.id == id }) else { return nil }
            let pointer = divider.axis == .horizontal ? point.x : point.y
            let start = divider.axis == .horizontal ? divider.frame.minX : divider.frame.minY
            let tree = layout.tree(containing: id)
            var drag = DividerDragState(kind: kind, transaction: .make(), grabOffset: pointer - start, container: divider.container,
                                        axis: divider.axis, minimumA: divider.minimumA, minimumB: divider.minimumB,
                                        snaps: DividerDragState.snaps(equalShare: tree?.equalizedRatio(for: id)))
            drag.tree = tree
            // Option pushes only what scrolls: a split across a strip column.
            if divider.axis == .horizontal, screen.scrolls(kind),
               let column = layout.columns.first(where: { $0.trees.contains { $0.node(for: id) != nil } }) {
                let viewport = screen.geometry.stripWidth
                drag.push = PushResize(split: id, column: column,
                                       columnWidth: ColumnStripGeometry.pixelWidth(fraction: column.width, viewportWidth: viewport, gap: style.stripGap),
                                       dividers: screen.geometry.dividers, viewport: viewport, gap: style.stripGap,
                                       dividerThickness: style.dividerThickness)
            }
            return drag
        case let .columnEdge(id):
            guard let frame = screen.geometry.columns[id] else { return nil }
            let size = layout.columns.first { $0.id == id }.map { $0.minimumSize(style: style) } ?? .zero
            let edge = screen.geometry.columnEdges.first { $0.column == id }?.dockEdge
            let grab: CGFloat = switch edge {
            case .right?: point.x - frame.minX
            case .top?: point.y - frame.maxY
            case .bottom?: point.y - frame.minY
            case .left?, nil: point.x - frame.maxX
            }
            let band = edge?.isBand == true
            var drag = DividerDragState(kind: kind, transaction: .make(), grabOffset: grab, container: frame,
                                        axis: band ? .vertical : .horizontal, minimumA: band ? size.height : size.width, dockEdge: edge)
            if edge == nil {
                let scrolling = DockStripGeometry.docks(layout.columns).scrolling
                drag.strip = StripStart(columns: scrolling.map { .init(id: $0.id, width: $0.width, minimum: $0.minimumSize(style: style).width) },
                                        viewport: screen.geometry.stripWidth, gap: style.stripGap)
            }
            return drag
        case let .rowEdge(columnID, upper):
            guard let column = layout.columns.first(where: { $0.id == columnID }), let stack = screen.baseGeometry.rowStacks[columnID],
                  let upperFrame = stack.frame(of: upper) else { return nil }
            let y = screen.convert(windowPoint, from: nil).y + screen.rowOffset(of: kind)
            let minimums = Dictionary(uniqueKeysWithValues: column.rows.map {
                ($0.id, SplitGeometry.minimumSize(of: $0.root, style: style).height)
            })
            return DividerDragState(kind: kind, transaction: .make(), grabOffset: y - upperFrame.maxY, container: stack.frame,
                                    axis: .vertical, rows: RowDragStart(rows: column.rows, stack: stack, minimums: minimums))
        }
    }
}
