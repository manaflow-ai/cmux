public import CmuxNextDesign
public import CoreGraphics

/// Geometry of the layout model prototypes. Each returns nil when the
/// screen has nothing to reinterpret, and the caller keeps the real layout.
public nonisolated enum LayoutModelPrototype {
    /// The largest share of the height a top or bottom dock takes
    /// (layout-model.md F3).
    public static let maxDockShare: CGFloat = 0.5

    public static func geometry(_ columns: [LayoutColumn], viewport: CGSize, style: LayoutStyle, scale: CGFloat) -> ScreenGeometry? {
        var plain = style
        plain.prototype = LayoutPrototypeSettings()
        switch style.prototype.model {
        case .off: return nil
        case .frameDocks:
            return frame(synthesizedDocks(columns, mode: style.prototype.dockMode), viewport: viewport, style: plain, edge: style.prototype.dockEdge,
                         orientation: style.prototype.orientation, scale: scale)
        case .grid: return grid(columns, viewport: viewport, style: plain, scale: scale)
        }
    }

    /// Screens without sticky columns (the pinned daemon may not serve them)
    /// get prototype docks from plain columns: the last strip column becomes
    /// the band and, with three or more strip columns, the first becomes the
    /// left dock. Real sticky columns are kept as they are.
    static func synthesizedDocks(_ columns: [LayoutColumn], mode: StickyMode) -> [LayoutColumn] {
        var result = columns
        let parts = StickyStripGeometry.partition(columns)
        var scrolling = parts.scrolling.map(\.id)
        if parts.right == nil, scrolling.count >= 2, let last = scrolling.popLast(),
           let index = result.firstIndex(where: { $0.id == last }) {
            result[index].sticky = StickyColumn(edge: .right, mode: mode)
        }
        if parts.left == nil, scrolling.count >= 2, let first = scrolling.first,
           let index = result.firstIndex(where: { $0.id == first }) {
            result[index].sticky = StickyColumn(edge: .left, mode: mode)
        }
        return result
    }

    /// Design A. The strip and the left dock are laid out in the height the
    /// band leaves. Column-major: the left dock then runs the full height and
    /// the band sits between the side docks. Row-major: the band runs the full
    /// width and the left dock stays between the top and bottom docks.
    static func frame(_ columns: [LayoutColumn], viewport: CGSize, style: LayoutStyle, edge: LayoutPrototypeDockEdge,
                      orientation: LayoutPrototypeOrientation, scale: CGFloat) -> ScreenGeometry? {
        let parts = StickyStripGeometry.partition(columns)
        guard let dock = parts.right, let sticky = dock.sticky else { return nil }
        let gap = style.stripGap
        let minimum = SplitGeometry.minimumSize(of: dock.root, style: style).height
        let share = min(max(CGFloat(dock.width), 0.1), maxDockShare)
        let bandHeight = SplitGeometry.roundToPixel(min(max(viewport.height * share, minimum), viewport.height * maxDockShare), scale: scale)
        let stripHeight = max(1, viewport.height - bandHeight - gap)
        let rest = columns.filter { $0.id != dock.id }
        var geometry = ScreenGeometry.compute(.columns(rest), viewport: CGSize(width: viewport.width, height: stripHeight), style: style, scale: scale)
        geometry.viewport = viewport
        if edge == .top { geometry.shift(dy: bandHeight + gap) }
        // Column-major: the left dock runs the full height.
        if orientation == .columnMajor, let index = geometry.sticky.firstIndex(where: { $0.sticky.edge == .left }),
           let left = columns.first(where: { $0.id == geometry.sticky[index].column }) {
            var entry = geometry.sticky[index]
            entry.frame = CGRect(x: entry.frame.minX, y: 0, width: entry.frame.width, height: viewport.height)
            entry.glass = CGRect(x: entry.glass.minX, y: 0, width: entry.glass.width, height: viewport.height)
            entry.cover = CGRect(x: entry.cover.minX, y: 0, width: entry.cover.width, height: viewport.height)
            geometry.sticky[index] = entry
            geometry.relayout(left.root, in: entry.frame, style: style, scale: scale)
        }
        let leftEdge = orientation == .rowMajor ? gap : geometry.sticky.first { $0.sticky.edge == .left }.map { $0.frame.maxX + gap } ?? gap
        let y = edge == .top ? 0 : viewport.height - bandHeight
        let band = CGRect(x: leftEdge, y: y, width: max(1, viewport.width - gap - leftEdge), height: bandHeight)
        let glass = band.insetBy(dx: -gap / 2, dy: -gap / 2).intersection(CGRect(origin: .zero, size: viewport))
        let cover = CGRect(x: band.minX, y: edge == .top ? 0 : band.minY - gap, width: band.width, height: bandHeight + gap)
        geometry.sticky.append(StickyColumnFrame(column: dock.id, sticky: sticky, frame: band, cover: cover, glass: glass))
        geometry.columns[dock.id] = band
        geometry.relayout(dock.root, in: band, style: style, scale: scale)
        return geometry
    }

    /// Design B. Columns keep their strip frames; pane `i` of every column
    /// sits in grid row `i`, all rows one height. A column with fewer panes
    /// leaves holes, and in-column dividers go away (cells do not split).
    static func grid(_ columns: [LayoutColumn], viewport: CGSize, style: LayoutStyle, scale: CGFloat) -> ScreenGeometry? {
        var geometry = ScreenGeometry.compute(.columns(columns), viewport: viewport, style: style, scale: scale)
        let scrolling = columns.filter { geometry.columnOrder.contains($0.id) }
        let rows = scrolling.map(\.root.panes.count).max() ?? 0
        guard rows > 1 else { return nil }
        let gap = style.stripGap
        let rowHeight = SplitGeometry.roundToPixel((viewport.height - gap * CGFloat(rows - 1)) / CGFloat(rows), scale: scale)
        for column in scrolling {
            guard let frame = geometry.columns[column.id] else { continue }
            for (index, pane) in column.root.panes.enumerated() {
                geometry.panes[pane] = CGRect(x: frame.minX, y: CGFloat(index) * (rowHeight + gap), width: frame.width, height: rowHeight)
            }
        }
        geometry.dividers.removeAll { !geometry.fixedSplits.contains($0.id) }
        return geometry
    }
}

nonisolated extension ScreenGeometry {
    /// Moves every frame down by `dy` (the frame prototype's top dock).
    mutating func shift(dy: CGFloat) {
        func moved(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: 0, dy: dy) }
        panes = panes.mapValues(moved)
        columns = columns.mapValues(moved)
        dividers = dividers.map { divider in
            var divider = divider
            divider.frame = moved(divider.frame)
            divider.hitFrame = moved(divider.hitFrame)
            divider.container = moved(divider.container)
            return divider
        }
        columnEdges = columnEdges.map { edge in
            var edge = edge
            edge.columnFrame = moved(edge.columnFrame)
            edge.hitFrame = moved(edge.hitFrame)
            return edge
        }
        gapZones = gapZones.map { zone in
            var zone = zone
            zone.frame = moved(zone.frame)
            return zone
        }
        sticky = sticky.map { entry in
            var entry = entry
            entry.frame = moved(entry.frame)
            entry.glass = moved(entry.glass)
            entry.cover = moved(entry.cover)
            return entry
        }
    }

    /// Lays a fixed split tree out again at `frame` (prototype docks).
    mutating func relayout(_ root: SplitNode, in frame: CGRect, style: LayoutStyle, scale: CGFloat) {
        let result = SplitGeometry.layout(root, in: frame, style: style, scale: scale)
        let ids = Set(result.dividers.map(\.id))
        dividers.removeAll { ids.contains($0.id) }
        panes.merge(result.panes) { _, new in new }
        fixedPanes.formUnion(result.panes.keys)
        dividers.append(contentsOf: result.dividers)
        fixedSplits.formUnion(ids)
    }
}
