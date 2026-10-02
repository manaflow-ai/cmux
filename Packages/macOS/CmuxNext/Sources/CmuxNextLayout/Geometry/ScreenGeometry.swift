public import CoreGraphics

/// Resize handle on a column's trailing edge (columns mode). A sticky
/// column's handle is on its inner edge: the leading edge of a right-edge
/// column, which grows to the left.
public nonisolated struct ColumnEdgeGeometry: Hashable, Sendable {
    public var column: ColumnID
    public var columnFrame: CGRect
    public var hitFrame: CGRect
    /// Set for a sticky column's handle (view coordinates, fixed).
    public var stickyEdge: StickyEdge? = nil
}

/// A "new column" drop zone centered on a column gap.
public nonisolated struct ColumnGapZone: Hashable, Sendable {
    /// Insert after this column; nil = before the first column.
    public var after: ColumnID?
    public var frame: CGRect
}

/// All frames for one screen, in content space (top-left origin; in columns
/// mode, x runs over the full scrollable strip, starting at the strip's own
/// origin `stripMinX`). Sticky columns, their panes and dividers are in view
/// coordinates and never scroll (`fixedPanes`, `fixedSplits`, `sticky`).
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
    /// docked sticky column they are 0 and the viewport width.
    public var stripMinX: CGFloat = 0
    public var stripWidth: CGFloat = 0
    /// The x range of the strip nothing covers (view coordinates).
    public var uncoveredMinX: CGFloat = 0
    public var uncoveredMaxX: CGFloat = 0
    /// Where strip panes are clipped (view coordinates).
    public var clipMinX: CGFloat = 0
    public var clipMaxX: CGFloat = 0
    /// Sticky columns at their edges, and what of them never scrolls.
    public var sticky: [StickyColumnFrame] = []
    public var fixedPanes: Set<PaneID> = []
    public var fixedSplits: Set<SplitID> = []

    public static func compute(_ layout: ScreenLayout, viewport: CGSize, style: LayoutStyle, scale: CGFloat = 2) -> ScreenGeometry {
        switch layout {
        case let .splits(root):
            let result = SplitGeometry.layout(root, in: CGRect(origin: .zero, size: viewport), style: style, scale: scale)
            return ScreenGeometry(viewport: viewport, panes: result.panes, dividers: result.dividers, contentWidth: viewport.width, isColumns: false,
                                  stripWidth: viewport.width, uncoveredMaxX: viewport.width, clipMaxX: viewport.width)
        case let .columns(all):
            if style.prototype.model != .off,
               let prototype = LayoutModelPrototype.geometry(all, viewport: viewport, style: style, scale: scale) {
                return prototype
            }
            let gap = style.stripGap
            let parts = StickyStripGeometry.partition(all)
            func minimum(_ column: LayoutColumn) -> CGFloat { SplitGeometry.minimumSize(of: column.root, style: style).width }
            let placement = StickyStripGeometry.place(
                left: parts.left.map { ($0, minimum($0)) }, right: parts.right.map { ($0, minimum($0)) },
                viewport: viewport, gap: gap, scale: scale
            )
            let columns = parts.scrolling
            let stripViewport = CGSize(width: placement.stripWidth, height: viewport.height)
            var strip = ColumnStripGeometry.frames(widths: columns.map(\.width), viewport: stripViewport, gap: gap, scale: scale,
                                                   minimumWidths: columns.map(minimum))
            if placement.leadingInset > 0 || placement.trailingInset > 0 {
                strip.frames = strip.frames.map { $0.offsetBy(dx: placement.leadingInset, dy: 0) }
                strip.contentWidth += placement.leadingInset + placement.trailingInset
            }
            var geometry = ScreenGeometry(viewport: viewport, contentWidth: strip.contentWidth, isColumns: true,
                                          stripMinX: placement.stripMinX, stripWidth: placement.stripWidth,
                                          uncoveredMinX: placement.uncoveredMinX, uncoveredMaxX: placement.uncoveredMaxX,
                                          clipMinX: placement.clipMinX, clipMaxX: placement.clipMaxX, sticky: placement.sticky)
            let edgeHit = style.columnEdgeHitThickness
            let dropWidth = max(gap, style.newColumnDropWidth)
            let firstGapMid = (strip.frames.first?.minX ?? gap) - gap / 2
            geometry.gapZones.append(ColumnGapZone(after: nil, frame: CGRect(x: firstGapMid - dropWidth / 2, y: 0, width: dropWidth, height: viewport.height)))
            for (column, frame) in zip(columns, strip.frames) {
                geometry.columns[column.id] = frame
                geometry.columnOrder.append(column.id)
                let result = SplitGeometry.layout(column.root, in: frame, style: style, scale: scale)
                geometry.panes.merge(result.panes) { _, new in new }
                geometry.dividers.append(contentsOf: result.dividers)
                let gapMid = frame.maxX + gap / 2
                geometry.columnEdges.append(ColumnEdgeGeometry(
                    column: column.id,
                    columnFrame: frame,
                    hitFrame: CGRect(x: gapMid - edgeHit / 2, y: 0, width: edgeHit, height: viewport.height)
                ))
                geometry.gapZones.append(ColumnGapZone(after: column.id, frame: CGRect(x: gapMid - dropWidth / 2, y: 0, width: dropWidth, height: viewport.height)))
            }
            geometry.snapOffsets = ColumnStripGeometry.snapOffsets(frames: strip.frames, contentWidth: strip.contentWidth,
                                                                   viewportWidth: placement.stripWidth, gap: gap)
            for entry in placement.sticky {
                guard let column = all.first(where: { $0.id == entry.column }) else { continue }
                geometry.addSticky(column, frame: entry, style: style, scale: scale)
            }
            return geometry
        }
    }

    public var maxOffset: CGFloat {
        ColumnStripGeometry.maxOffset(contentWidth: contentWidth, viewportWidth: stripWidth)
    }

    /// Lays out a sticky column's split tree at its fixed frame, with its
    /// resize handle on the inner edge.
    private mutating func addSticky(_ column: LayoutColumn, frame entry: StickyColumnFrame, style: LayoutStyle, scale: CGFloat) {
        let result = SplitGeometry.layout(column.root, in: entry.frame, style: style, scale: scale)
        columns[column.id] = entry.frame
        panes.merge(result.panes) { _, new in new }
        fixedPanes.formUnion(result.panes.keys)
        dividers.append(contentsOf: result.dividers)
        fixedSplits.formUnion(result.dividers.map(\.id))
        // The handle sits on the column's own inner edge, so the gap beside
        // it stays with the neighboring strip column's handle (both resize).
        let edgeHit = style.columnEdgeHitThickness
        let x = entry.sticky.edge == .left ? entry.frame.maxX - edgeHit + 1 : entry.frame.minX - 1
        columnEdges.append(ColumnEdgeGeometry(
            column: column.id, columnFrame: entry.frame,
            hitFrame: CGRect(x: x, y: 0, width: edgeHit, height: viewport.height),
            stickyEdge: entry.sticky.edge
        ))
    }

    /// True for a pane, divider or column edge that the scroll moves.
    public func scrolls(pane: PaneID) -> Bool { !fixedPanes.contains(pane) }

    /// The view x of strip content x at scroll `offset`.
    public func viewShift(offset: CGFloat) -> CGFloat { stripMinX - offset }

    /// The sticky column holding `pane`, if any.
    public func stickyFrame(containing pane: PaneID) -> StickyColumnFrame? {
        guard fixedPanes.contains(pane), let rect = panes[pane] else { return nil }
        return sticky.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
    }

    /// Column frames in column order.
    public var orderedColumnFrames: [CGRect] { columnOrder.compactMap { columns[$0] } }
}
