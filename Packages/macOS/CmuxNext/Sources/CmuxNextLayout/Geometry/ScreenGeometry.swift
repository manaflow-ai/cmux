public import CoreGraphics

/// Resize handle on a column's trailing edge (columns mode).
public nonisolated struct ColumnEdgeGeometry: Hashable, Sendable {
    public var column: ColumnID
    public var columnFrame: CGRect
    public var hitFrame: CGRect
}

/// A "new column" drop zone centered on a column gap.
public nonisolated struct ColumnGapZone: Hashable, Sendable {
    /// Insert after this column; nil = before the first column.
    public var after: ColumnID?
    public var frame: CGRect
}

/// All frames for one screen, in content space (top-left origin; in columns
/// mode, x runs over the full scrollable strip).
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

    public static func compute(_ layout: ScreenLayout, viewport: CGSize, style: LayoutStyle, scale: CGFloat = 2) -> ScreenGeometry {
        switch layout {
        case let .splits(root):
            let result = SplitGeometry.layout(root, in: CGRect(origin: .zero, size: viewport), style: style, scale: scale)
            return ScreenGeometry(viewport: viewport, panes: result.panes, dividers: result.dividers, contentWidth: viewport.width, isColumns: false)
        case let .columns(columns):
            let gap = style.stripGap
            let minimums = columns.map { SplitGeometry.minimumSize(of: $0.root, style: style).width }
            let strip = ColumnStripGeometry.frames(widths: columns.map(\.width), viewport: viewport, gap: gap, scale: scale,
                                                   minimumWidths: minimums)
            var geometry = ScreenGeometry(viewport: viewport, contentWidth: strip.contentWidth, isColumns: true)
            let edgeHit = style.columnEdgeHitThickness
            let dropWidth = max(gap, style.newColumnDropWidth)
            geometry.gapZones.append(ColumnGapZone(after: nil, frame: CGRect(x: gap / 2 - dropWidth / 2, y: 0, width: dropWidth, height: viewport.height)))
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
            geometry.snapOffsets = ColumnStripGeometry.snapOffsets(frames: strip.frames, contentWidth: strip.contentWidth, viewportWidth: viewport.width, gap: gap)
            return geometry
        }
    }

    public var maxOffset: CGFloat {
        ColumnStripGeometry.maxOffset(contentWidth: contentWidth, viewportWidth: viewport.width)
    }

    /// Column frames in column order.
    public var orderedColumnFrames: [CGRect] { columnOrder.compactMap { columns[$0] } }
}
