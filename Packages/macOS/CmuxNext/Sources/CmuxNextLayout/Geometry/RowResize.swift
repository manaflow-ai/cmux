public import CoreGraphics

/// Row divider drags (plans/cmux-next/rows.md Z1). Pure: the view passes the
/// rows and their frames from when the drag began.
public nonisolated struct RowResize {
    public nonisolated init() {}
    /// Every row height after dragging the edge below `upper` so that row's
    /// bottom sits at `pointerY` (content space). Filled rows (sum at most
    /// 1000, or rows off) trade height with the row below, keeping their
    /// sum; scrolling rows change `upper` only. Each row keeps 100 permille
    /// and the height its tree needs (`minimums`, points) where it can.
    public static func heights(_ rows: [LayoutRow], stack: RowStackGeometry, upper: RowID, pointerY: CGFloat,
                               minimums: [RowID: CGFloat] = [:], fits: Bool = false) -> [RowHeight] {
        var result = rows.map { RowHeight(row: $0.id, height: $0.height) }
        guard let index = rows.firstIndex(where: { $0.id == upper }), index + 1 < rows.count,
              index + 1 < stack.rows.count else { return result }
        let floor = LayoutRow.heightRange.lowerBound
        let upperFrame = stack.rows[index].frame
        let minUpper = minimums[upper] ?? 0
        let sum = rows.reduce(0) { $0 + $1.height }
        if fits || sum <= 1000 {
            let lowerFrame = stack.rows[index + 1].frame
            let pairPixels = upperFrame.height + lowerFrame.height
            let minLower = minimums[rows[index + 1].id] ?? 0
            var pixels = pointerY - upperFrame.minY
            pixels = minUpper + minLower <= pairPixels ? min(max(pixels, minUpper), pairPixels - minLower) : min(max(pixels, 0), pairPixels)
            let pair = rows[index].height + rows[index + 1].height
            guard pair >= floor * 2, pairPixels > 0 else { return result }
            let share = min(max(Int((Double(pair) * Double(pixels / pairPixels)).rounded()), floor), pair - floor)
            result[index].height = share
            result[index + 1].height = pair - share
        } else {
            let pixels = max(pointerY - upperFrame.minY, minUpper)
            result[index].height = RowStackGeometry.permille(forPixelHeight: pixels, columnHeight: stack.frame.height, gap: stack.gap)
        }
        return result
    }
}
