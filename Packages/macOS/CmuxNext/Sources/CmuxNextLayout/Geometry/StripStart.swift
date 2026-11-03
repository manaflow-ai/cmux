public import CoreGraphics

/// The scrolling columns of a strip when a column-edge drag began, for the modifier modes
/// (resize-modifiers.md): Option trades width with the next column, Command gives every column the
/// dragged one's width. Pure, so each frame derives from the start.
public nonisolated struct StripStart: Hashable, Sendable {
    public struct Column: Hashable, Sendable {
        public var id: ColumnID
        /// Width share at the start.
        public var width: Double
        /// Narrowest width in points that keeps every pane at its minimum.
        public var minimum: CGFloat

        public init(id: ColumnID, width: Double, minimum: CGFloat) {
            self.id = id
            self.width = width
            self.minimum = minimum
        }
    }

    /// Scrolling columns left to right.
    public var columns: [Column]
    public var viewport: CGFloat
    public var gap: CGFloat

    public init(columns: [Column], viewport: CGFloat, gap: CGFloat) {
        self.columns = columns
        self.viewport = viewport
        self.gap = gap
    }

    func points(_ fraction: Double) -> CGFloat {
        ColumnStripGeometry.pixelWidth(fraction: fraction, viewportWidth: viewport, gap: gap)
    }

    func fraction(_ points: CGFloat) -> Double {
        ColumnStripGeometry.fraction(forPixelWidth: points, viewportWidth: viewport, gap: gap)
    }

    /// The column after `column`, if any: the one Option trades with.
    public func next(after column: ColumnID) -> Column? {
        guard let index = columns.firstIndex(where: { $0.id == column }), index + 1 < columns.count else { return nil }
        return columns[index + 1]
    }

    /// Option: `column` takes `width`, and the next column gives up (or takes back) the same points,
    /// within its minimum and the widest share, so the columns after them stay where they are.
    /// Without a next column, only `column` changes.
    public func trading(_ column: ColumnID, to width: Double) -> [DividerDragValue] {
        guard let start = columns.first(where: { $0.id == column }), let next = next(after: column) else {
            return [.width(column, width)]
        }
        let widest = points(ColumnWidthPreset.widthRange.upperBound)
        var delta = points(width) - points(start.width)
        let nextStart = points(next.width)
        delta = min(delta, nextStart - max(next.minimum, points(ColumnWidthPreset.widthRange.lowerBound)))
        delta = max(delta, nextStart - widest)
        return [.width(column, fraction(points(start.width) + delta)), .width(next.id, fraction(nextStart - delta))]
    }

    /// Command: every scrolling column takes `width`, widened to the share the widest minimum needs.
    public func uniform(_ width: Double) -> [DividerDragValue] {
        let floor = columns.map { fraction($0.minimum) }.max() ?? width
        let shared = max(width, floor)
        return columns.map { .width($0.id, shared) }
    }
}
