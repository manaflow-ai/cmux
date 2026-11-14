public import CoreGraphics

/// The column widths Equalize Splits gives a columns screen (Lawrence 2026-11-05: "cmd ctrl = fails to equalize home
/// imessage/chief and the stuff on the right"): every column a person sees side by side gets the same width on screen.
///
/// - A docked left or right dock (Home's Chief chat) counts as one of those columns. Its width is a share of the whole
///   window and the strip's columns share what it leaves, so its fraction is solved from the pixel width all columns
///   get: `W = (viewport - (docks + strip columns + 1) * gap) / (docks + strip columns)`. It never goes below its panes'
///   minimum width (the chat's) or above the share a dock may take (`DockStripGeometry`); then the strip columns still
///   share the rest equally.
/// - The strip's columns each get `1 / n` of the strip: `n` is every strip column when all of them fit beside the docks
///   at their minimum width, so they all share the window; else the strip columns the window shows (any part of them),
///   so those fill it, and the ones scrolled out get the same width.
/// - An overlay dock floats over the strip and a top or bottom dock is a band: neither shares the width, both keep it.
///   A dock alone on its screen fills it (`pinned-dock-alone-v1`) and keeps its width.
///
/// ```swift
/// let resizes = ColumnEqualizer(columns: columns, visible: ["c1"], viewportWidth: 1440, gap: 8) {
///     $0.minimumSize(style: style).width
/// }.resizes
/// ```
public nonisolated struct ColumnEqualizer {
    /// The screen's columns, in daemon order.
    public var columns: [LayoutColumn]
    /// The strip columns the window shows now (any part of them); empty when unknown.
    public var visible: Set<ColumnID>
    /// The screen's viewport width in points.
    public var viewportWidth: CGFloat
    /// The strip gap (`LayoutStyle.stripGap`).
    public var gap: CGFloat
    /// A column's minimum width in points (`LayoutColumn.minimumSize(style:)`).
    public var minimumWidth: (LayoutColumn) -> CGFloat

    /// - Parameters:
    ///   - columns: The screen's columns.
    ///   - visible: The strip columns in view; empty counts every strip column.
    ///   - viewportWidth: The screen's width in points.
    ///   - gap: The strip gap in points.
    ///   - minimumWidth: Each column's minimum width in points.
    public init(columns: [LayoutColumn], visible: Set<ColumnID> = [], viewportWidth: CGFloat, gap: CGFloat,
                minimumWidth: @escaping (LayoutColumn) -> CGFloat) {
        self.columns = columns
        self.visible = visible
        self.viewportWidth = viewportWidth
        self.gap = gap
        self.minimumWidth = minimumWidth
    }

    /// The widths that differ from the ones the columns have; empty when they are equal already.
    public var resizes: [ColumnResize] {
        let parts = DockStripGeometry.docks(columns)
        let strip = parts.scrolling.filter { $0.dock == nil }
        guard !strip.isEmpty else { return [] }
        let range = ColumnWidthPreset.widthRange
        func clamped(_ value: Double) -> Double { min(max(value, range.lowerBound), range.upperBound) }
        var result: [ColumnResize] = []
        func set(_ column: LayoutColumn, _ width: Double) {
            if abs(column.width - width) > 0.001 { result.append(ColumnResize(column: column.id, width: width)) }
        }
        let sides = [parts.left, parts.right].compactMap { $0 }.filter { $0.dock?.mode == .docked }
        /// The width each of `count` columns gets, the docks included.
        func equalWidth(stripColumns count: Int) -> CGFloat {
            let total = CGFloat(sides.count + count)
            return (viewportWidth - (total + 1) * gap) / total
        }
        let widest = strip.map(minimumWidth).max() ?? 0
        let fitsAll = 1.0 / Double(strip.count) >= range.lowerBound
            && (viewportWidth <= 0 || equalWidth(stripColumns: strip.count) >= widest)
        let shown = strip.filter { visible.contains($0.id) }.count
        let stripCount = fitsAll || shown == 0 ? strip.count : shown
        if !sides.isEmpty, viewportWidth > gap {
            let equal = equalWidth(stripColumns: stripCount)
            let share = (parts.left != nil && parts.right != nil ? DockStripGeometry.maxShareBoth : DockStripGeometry.maxShare) * viewportWidth
            for dock in sides {
                let width = min(max(equal, minimumWidth(dock)), share)
                set(dock, clamped(ColumnStripGeometry.fraction(forPixelWidth: width, viewportWidth: viewportWidth, gap: gap)))
            }
        }
        let each = clamped(1.0 / Double(stripCount))
        for column in strip { set(column, each) }
        return result
    }
}
