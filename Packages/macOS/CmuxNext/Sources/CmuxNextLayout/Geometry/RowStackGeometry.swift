public import CoreGraphics

/// One row placed in its column, in content space (unscrolled: the column's
/// vertical offset is not applied).
public nonisolated struct RowFrame: Hashable, Sendable {
    public var id: RowID
    public var frame: CGRect
}

/// The resize handle between two rows of a column, in the gap between them
/// (content space). Dragging it changes `upper`'s height (rows.md Z1).
public nonisolated struct RowEdgeGeometry: Hashable, Sendable {
    public var column: ColumnID
    public var upper: RowID
    public var lower: RowID
    public var hitFrame: CGRect
}

/// The rows of one column (plans/cmux-next/rows.md, Geometry): where each row
/// sits, how tall the stack is and whether it scrolls vertically.
public nonisolated struct RowStackGeometry: Hashable, Sendable {
    public var column: ColumnID
    /// The column's frame: the window the rows show through.
    public var frame: CGRect
    public var rows: [RowFrame]
    /// Height of the whole stack; more than `frame.height` scrolls (G2).
    public var contentHeight: CGFloat
    public var gap: CGFloat

    /// The rows overflow the column, which scrolls them vertically.
    public var scrolls: Bool { contentHeight > frame.height + 0.5 }
    public var maxOffset: CGFloat { max(0, contentHeight - frame.height) }

    /// Pixel height of a row of `permille` in a column `height` tall. G1
    /// with gaps only between rows: `(height + gap) * p - gap`, so one row of
    /// 1000 is the column and two of 500 plus their gap fill it exactly.
    public static func pixelHeight(permille: Double, columnHeight: CGFloat, gap: CGFloat) -> CGFloat {
        max(1, (columnHeight + gap) * CGFloat(permille) / 1000 - gap)
    }

    /// Inverse of `pixelHeight`, clamped to 100...1000.
    public static func permille(forPixelHeight height: CGFloat, columnHeight: CGFloat, gap: CGFloat) -> Int {
        let denominator = columnHeight + gap
        guard denominator > 0 else { return LayoutRow.heightRange.upperBound }
        let value = Int(((height + gap) / denominator * 1000).rounded())
        return min(max(value, LayoutRow.heightRange.lowerBound), LayoutRow.heightRange.upperBound)
    }

    /// Places `rows` top to bottom in `frame`. G2: heights summing to at most
    /// 1000 fill the column in proportion; above 1000 they keep their heights
    /// and the stack scrolls. `fits` (rows turned off, O3) always fills in
    /// proportion and never scrolls. A row keeps the height its split tree
    /// needs (`minimumHeights`) unless `fits` cannot give it.
    public static func compute(column: ColumnID, rows: [LayoutRow], minimumHeights: [CGFloat] = [], in frame: CGRect,
                               gap: CGFloat, fits: Bool = false, scale: CGFloat = 2) -> RowStackGeometry {
        let sum = rows.reduce(0) { $0 + max($1.height, 1) }
        let fill = fits || sum <= 1000
        let factor = fill && sum > 0 ? 1000 / Double(sum) : 1
        var heights = rows.map { row in
            SplitGeometry.roundToPixel(pixelHeight(permille: Double(max(row.height, 1)) * factor, columnHeight: frame.height, gap: gap),
                                       scale: scale)
        }
        let withMinimums = heights.enumerated().map { index, height in
            index < minimumHeights.count ? max(height, SplitGeometry.ceilToPixel(minimumHeights[index], scale: scale)) : height
        }
        let available = frame.height - gap * CGFloat(max(rows.count - 1, 0))
        if !fits || withMinimums.reduce(0, +) <= available + 0.5 { heights = withMinimums }
        var y = frame.minY
        var placed: [RowFrame] = []
        for (index, row) in rows.enumerated() {
            var height = heights[index]
            // A filled stack ends exactly at the column's bottom edge.
            if fill, index == rows.count - 1, heights.reduce(0, +) <= available + 0.5 { height = max(1, frame.maxY - y) }
            placed.append(RowFrame(id: row.id, frame: CGRect(x: frame.minX, y: y, width: frame.width, height: height)))
            y += height + gap
        }
        let content = placed.last.map { $0.frame.maxY - frame.minY } ?? frame.height
        return RowStackGeometry(column: column, frame: frame, rows: placed, contentHeight: fits ? min(content, frame.height) : content, gap: gap)
    }

    /// The handles between neighboring rows, `thickness` tall, centered on
    /// each gap.
    public func edges(thickness: CGFloat) -> [RowEdgeGeometry] {
        zip(rows, rows.dropFirst()).map { upper, lower in
            let mid = (upper.frame.maxY + lower.frame.minY) / 2
            return RowEdgeGeometry(column: column, upper: upper.id, lower: lower.id,
                                   hitFrame: CGRect(x: frame.minX, y: mid - thickness / 2, width: frame.width, height: thickness))
        }
    }

    public func frame(of row: RowID) -> CGRect? { rows.first { $0.id == row }?.frame }
}
