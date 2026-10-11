public import CmuxNextDesign
public import CoreGraphics

/// Resize handle on a column's trailing edge (columns mode). A docked
/// column's handle is on its inner edge: the leading edge of a right-edge
/// column, which grows to the left.
public nonisolated struct ColumnEdgeGeometry: Hashable, Sendable {
    public var column: ColumnID
    public var columnFrame: CGRect
    public var hitFrame: CGRect
    /// Set for a docked column's handle (view coordinates, fixed).
    public var dockEdge: DockEdge? = nil
    /// Horizontal for a column edge; vertical for a top or bottom dock's
    /// inner edge (a horizontal line dragged up and down).
    public var axis: SplitAxis = .horizontal
}

/// A "new column" drop zone centered on a column gap.
public nonisolated struct ColumnGapZone: Hashable, Sendable {
    /// Insert after this column; nil = before the first column.
    public var after: ColumnID?
    public var frame: CGRect
}

/// All frames for one screen, in content space (top-left origin; in columns
/// mode, x runs over the full scrollable strip, starting at the strip's own
/// origin `stripMinX`). Docked columns, their panes and dividers are in view
/// coordinates and never scroll (`fixedPanes`, `fixedSplits`, `dock`).
public nonisolated struct ScreenGeometry: Hashable, Sendable {
    public var viewport: CGSize
    public var panes: [PaneID: CGRect] = [:]
    public var dividers: [DividerGeometry] = []
    public var columns: [ColumnID: CGRect] = [:]
    public var columnOrder: [ColumnID] = []
    public var columnEdges: [ColumnEdgeGeometry] = []
    public var gapZones: [ColumnGapZone] = []
    public var contentWidth: CGFloat
    public var snapOffsets: [CGFloat] = [0]
    public var isColumns: Bool
    /// The strip's origin and viewport width in view coordinates. Without a
    /// docked docked column they are 0 and the viewport width.
    public var stripMinX: CGFloat = 0
    public var stripWidth: CGFloat = 0
    /// The strip's vertical range in view coordinates: top and bottom docks
    /// move it (layout-model.md F2). Without them, 0 and the viewport height.
    public var stripMinY: CGFloat = 0
    public var stripHeight: CGFloat = 0
    /// The x range of the strip nothing covers (view coordinates).
    public var uncoveredMinX: CGFloat = 0
    public var uncoveredMaxX: CGFloat = 0
    public var uncoveredMinY: CGFloat = 0
    public var uncoveredMaxY: CGFloat = 0
    /// Where strip panes are clipped (view coordinates).
    public var clipMinX: CGFloat = 0
    public var clipMaxX: CGFloat = 0
    public var clipMinY: CGFloat = 0
    public var clipMaxY: CGFloat = 0
    /// Docked columns at their edges, and what of them never scrolls.
    public var dock: [DockColumnFrame] = []
    public var fixedPanes: Set<PaneID> = []
    /// The orientation the docks were placed with; stacking reads it (F4).
    public var frameOrientation: FrameOrientation = .columnMajor
    public var fixedSplits: Set<SplitID> = []
    /// Columns with two or more rows (plans/cmux-next/rows.md), their row
    /// frames and the handles between rows. Row content is in content space
    /// before the column's own vertical offset (`shiftingRows`).
    public var rowStacks: [ColumnID: RowStackGeometry] = [:]
    public var rowEdges: [RowEdgeGeometry] = []
    /// The row column holding each pane and split divider: what that
    /// column's vertical offset moves.
    public var rowColumnOfPane: [PaneID: ColumnID] = [:]
    public var rowColumnOfSplit: [SplitID: ColumnID] = [:]

    public static func compute(_ layout: ScreenLayout, viewport: CGSize, style: LayoutStyle, scale: CGFloat = 2) -> ScreenGeometry {
        switch layout {
        case let .splits(root):
            let result = SplitGeometry.layout(root, in: CGRect(origin: .zero, size: viewport), style: style, scale: scale)
            return ScreenGeometry(viewport: viewport, panes: result.panes, dividers: result.dividers, contentWidth: viewport.width, isColumns: false,
                                  stripWidth: viewport.width, stripHeight: viewport.height, uncoveredMaxX: viewport.width,
                                  uncoveredMaxY: viewport.height, clipMaxX: viewport.width, clipMaxY: viewport.height)
        case let .columns(all):
            if style.prototype.model != .off,
               let prototype = LayoutModelPrototype.geometry(all, viewport: viewport, style: style, scale: scale) {
                return prototype
            }
            let gap = style.stripGap
            let parts = DockStripGeometry.docks(all)
            func minimum(_ column: LayoutColumn) -> CGFloat { SplitGeometry.minimumSize(of: column.root, style: style).width }
            func minimumHeight(_ column: LayoutColumn) -> CGFloat { SplitGeometry.minimumSize(of: column.root, style: style).height }
            let placement = DockStripGeometry.place(
                left: parts.left.map { ($0, minimum($0)) }, right: parts.right.map { ($0, minimum($0)) },
                top: parts.top.map { ($0, minimumHeight($0)) }, bottom: parts.bottom.map { ($0, minimumHeight($0)) },
                viewport: viewport, gap: gap, orientation: style.frameOrientation, scale: scale
            )
            let columns = parts.scrolling
            let stripViewport = CGSize(width: placement.stripWidth, height: placement.stripHeight)
            var strip = ColumnStripGeometry.frames(widths: columns.map(\.width), viewport: stripViewport, gap: gap, scale: scale,
                                                   minimumWidths: columns.map(minimum))
            if placement.leadingInset > 0 || placement.trailingInset > 0 || placement.stripMinY > 0 {
                strip.frames = strip.frames.map { $0.offsetBy(dx: placement.leadingInset, dy: placement.stripMinY) }
                strip.contentWidth += placement.leadingInset + placement.trailingInset
            }
            var geometry = ScreenGeometry(viewport: viewport, contentWidth: strip.contentWidth, isColumns: true,
                                          stripMinX: placement.stripMinX, stripWidth: placement.stripWidth,
                                          stripMinY: placement.stripMinY, stripHeight: placement.stripHeight,
                                          uncoveredMinX: placement.uncoveredMinX, uncoveredMaxX: placement.uncoveredMaxX,
                                          uncoveredMinY: placement.uncoveredMinY, uncoveredMaxY: placement.uncoveredMaxY,
                                          clipMinX: placement.clipMinX, clipMaxX: placement.clipMaxX,
                                          clipMinY: placement.clipMinY, clipMaxY: placement.clipMaxY, dock: placement.dock)
            geometry.frameOrientation = style.frameOrientation
            let stripY = placement.stripMinY, stripH = placement.stripHeight
            let edgeHit = style.columnEdgeHitThickness
            let dropWidth = max(gap, style.newColumnDropWidth)
            let firstGapMid = (strip.frames.first?.minX ?? gap) - gap / 2
            geometry.gapZones.append(ColumnGapZone(after: nil, frame: CGRect(x: firstGapMid - dropWidth / 2, y: stripY, width: dropWidth, height: stripH)))
            for (column, frame) in zip(columns, strip.frames) {
                geometry.columns[column.id] = frame
                geometry.columnOrder.append(column.id)
                let result = geometry.layoutContent(of: column, in: frame, style: style, scale: scale)
                geometry.panes.merge(result.panes) { _, new in new }
                geometry.dividers.append(contentsOf: result.dividers)
                let gapMid = frame.maxX + gap / 2
                geometry.columnEdges.append(ColumnEdgeGeometry(
                    column: column.id,
                    columnFrame: frame,
                    hitFrame: CGRect(x: gapMid - edgeHit / 2, y: stripY, width: edgeHit, height: stripH)
                ))
                geometry.gapZones.append(ColumnGapZone(after: column.id, frame: CGRect(x: gapMid - dropWidth / 2, y: stripY, width: dropWidth, height: stripH)))
            }
            geometry.snapOffsets = ColumnStripGeometry.snapOffsets(frames: strip.frames, contentWidth: strip.contentWidth,
                                                                   viewportWidth: placement.stripWidth, gap: gap)
            for entry in placement.dock {
                guard let column = all.first(where: { $0.id == entry.column }) else { continue }
                geometry.addDock(column, frame: entry, style: style, scale: scale)
            }
            return geometry
        }
    }

    public var maxOffset: CGFloat {
        ColumnStripGeometry.maxOffset(contentWidth: contentWidth, viewportWidth: stripWidth)
    }

    /// Lays out a docked column's split tree at its fixed frame, with its
    /// resize handle on the inner edge.
    private mutating func addDock(_ column: LayoutColumn, frame entry: DockColumnFrame, style: LayoutStyle, scale: CGFloat) {
        // G5: a docked column holds rows like any column.
        let result = layoutContent(of: column, in: entry.frame, style: style, scale: scale)
        columns[column.id] = entry.frame
        panes.merge(result.panes) { _, new in new }
        fixedPanes.formUnion(result.panes.keys)
        dividers.append(contentsOf: result.dividers)
        fixedSplits.formUnion(result.dividers.map(\.id))
        let edgeHit = style.columnEdgeHitThickness
        // A top or bottom dock's handle is a horizontal line on its inner
        // edge, dragged up and down (layout-model.md, dock resize).
        if entry.dock.edge.isBand {
            let y = entry.dock.edge == .top ? entry.frame.maxY - edgeHit + 1 : entry.frame.minY - 1
            columnEdges.append(ColumnEdgeGeometry(
                column: column.id, columnFrame: entry.frame,
                hitFrame: CGRect(x: entry.frame.minX, y: y, width: entry.frame.width, height: edgeHit),
                dockEdge: entry.dock.edge, axis: .vertical
            ))
            return
        }
        // The handle sits on the column's own inner edge, so the gap beside
        // it stays with the neighboring strip column's handle (both resize).
        let x = entry.dock.edge == .left ? entry.frame.maxX - edgeHit + 1 : entry.frame.minX - 1
        columnEdges.append(ColumnEdgeGeometry(
            column: column.id, columnFrame: entry.frame,
            hitFrame: CGRect(x: x, y: entry.frame.minY, width: edgeHit, height: entry.frame.height),
            dockEdge: entry.dock.edge
        ))
    }

    /// A column's panes and dividers in `frame`: its split tree, or its rows
    /// stacked top to bottom with each row's tree inside (rows.md G1, G2).
    /// Rows turned off (`style.rowsEnabled`) fit the column and never
    /// scroll (O3).
    mutating func layoutContent(of column: LayoutColumn, in frame: CGRect, style: LayoutStyle, scale: CGFloat) -> SplitLayoutResult {
        guard column.hasRows else { return SplitGeometry.layout(column.root, in: frame, style: style, scale: scale) }
        let stack = RowStackGeometry.compute(column: column.id, rows: column.rows,
                                             minimumHeights: column.rows.map { SplitGeometry.minimumSize(of: $0.root, style: style).height },
                                             in: frame, gap: style.stripGap, fits: !style.rowsEnabled, scale: scale)
        rowStacks[column.id] = stack
        rowEdges.append(contentsOf: stack.edges(thickness: style.columnEdgeHitThickness))
        var result = SplitLayoutResult()
        for (row, placed) in zip(column.rows, stack.rows) {
            let inner = SplitGeometry.layout(row.root, in: placed.frame, style: style, scale: scale)
            result.panes.merge(inner.panes) { _, new in new }
            result.dividers.append(contentsOf: inner.dividers)
        }
        for pane in result.panes.keys { rowColumnOfPane[pane] = column.id }
        for divider in result.dividers { rowColumnOfSplit[divider.id] = column.id }
        return result
    }

    /// This geometry with each row column's content moved up by its
    /// vertical offset (`offsets`, content points): what the view shows and
    /// hit-tests at those offsets. Column frames and row stacks stay.
    public func shiftingRows(_ offsets: [ColumnID: CGFloat]) -> ScreenGeometry {
        let live = offsets.filter { $0.value != 0 && rowStacks[$0.key] != nil }
        guard !live.isEmpty else { return self }
        var shifted = self
        for (pane, column) in rowColumnOfPane {
            guard let dy = live[column], let rect = panes[pane] else { continue }
            shifted.panes[pane] = rect.offsetBy(dx: 0, dy: -dy)
        }
        shifted.dividers = dividers.map { divider in
            guard let column = rowColumnOfSplit[divider.id], let dy = live[column] else { return divider }
            var moved = divider
            moved.frame = divider.frame.offsetBy(dx: 0, dy: -dy)
            moved.hitFrame = divider.hitFrame.offsetBy(dx: 0, dy: -dy)
            moved.container = divider.container.offsetBy(dx: 0, dy: -dy)
            return moved
        }
        shifted.rowEdges = rowEdges.map { edge in
            guard let dy = live[edge.column] else { return edge }
            var moved = edge
            moved.hitFrame = edge.hitFrame.offsetBy(dx: 0, dy: -dy)
            return moved
        }
        return shifted
    }

    /// True for a pane, divider or column edge that the scroll moves.
    public func scrolls(pane: PaneID) -> Bool { !fixedPanes.contains(pane) }

    /// The view x of strip content x at scroll `offset`.
    public func viewShift(offset: CGFloat) -> CGFloat { stripMinX - offset }

    /// The docked column holding `pane`, if any.
    public func dockFrame(containing pane: PaneID) -> DockColumnFrame? {
        guard fixedPanes.contains(pane), let rect = panes[pane] else { return nil }
        return dock.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
    }

    /// Column frames in column order.
    public var orderedColumnFrames: [CGRect] { columnOrder.compactMap { columns[$0] } }
}
