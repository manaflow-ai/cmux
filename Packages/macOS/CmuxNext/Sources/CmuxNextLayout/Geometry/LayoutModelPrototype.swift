public import CmuxNextDesign
public import CoreGraphics

/// Geometry of the layout model prototypes. Each returns nil when the
/// screen has nothing to reinterpret, and the caller keeps the real layout.
public nonisolated enum LayoutModelPrototype {
    public static func geometry(_ columns: [LayoutColumn], viewport: CGSize, style: LayoutStyle, scale: CGFloat) -> ScreenGeometry? {
        var plain = style
        plain.prototype = LayoutPrototypeSettings()
        switch style.prototype.model {
        case .off: return nil
        case .frameDocks:
            let docks = frameDocks(columns, settings: style.prototype)
            guard docks != columns else { return nil }
            plain.frameOrientation = style.prototype.orientation == .rowMajor ? .rowMajor : .columnMajor
            return ScreenGeometry.compute(.columns(docks), viewport: viewport, style: plain, scale: scale)
        case .grid: return grid(columns, viewport: viewport, style: plain, scale: scale)
        }
    }

    /// Design A through the real four-edge geometry: the screen's right dock
    /// (or, without sticky columns, its last strip column) becomes the top or
    /// bottom dock, and without a left sticky column the first strip column
    /// becomes the left dock when three or more remain. View-only.
    static func frameDocks(_ columns: [LayoutColumn], settings: LayoutPrototypeSettings) -> [LayoutColumn] {
        var result = synthesizedDocks(columns, mode: settings.dockMode)
        let band: StickyEdge = settings.dockEdge == .top ? .top : .bottom
        if let index = result.firstIndex(where: { $0.sticky?.edge == .right }), let sticky = result[index].sticky {
            result[index].sticky = StickyColumn(edge: band, mode: sticky.mode)
        }
        return result
    }

    /// Screens without sticky columns (the pinned daemon may not serve them)
    /// get prototype docks from plain columns: the last strip column becomes
    /// the right dock and, with three or more strip columns, the first
    /// becomes the left dock. Real sticky columns are kept as they are.
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
