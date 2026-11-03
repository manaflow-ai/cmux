public import CoreGraphics

/// The split ratios and column widths one screen can show as different layouts. Below or above them the
/// minimum pane sizes hold the divider where it is (``SplitGeometry/firstExtent(ratio:available:minimumA:minimumB:scale:)``,
/// ``ColumnStripGeometry/frames(widths:viewport:gap:scale:minimumWidths:)``): a keyboard resize step there would
/// change the model and move nothing (RESIZE KEYS, cmux-ad 2026-11-02, P0 "pixel perfect ctrl shift hjkl").
public nonisolated struct ShownResizeRange {
    let geometry: ScreenGeometry
    let style: LayoutStyle
    /// The device pixels per point the geometry was placed on (`ScreenGeometry.compute`'s `scale`).
    let scale: CGFloat
    /// Where the strip's camera rests (content-space x of its viewport's leading edge); nil when unknown.
    let stripOffset: CGFloat?

    /// - Parameters:
    ///   - geometry: The screen's geometry at its rest (the one its springs head for).
    ///   - style: The style that geometry was computed with.
    ///   - scale: The backing scale that geometry was computed at.
    ///   - stripOffset: Where the strip's camera rests: a trade's divider stays in the part of the strip it shows.
    public init(geometry: ScreenGeometry, style: LayoutStyle, scale: CGFloat = 2, stripOffset: CGFloat? = nil) {
        self.geometry = geometry
        self.style = style
        self.scale = scale
        self.stripOffset = stripOffset
    }

    /// The ratios of `split` that place its divider somewhere new: each side keeps its minimum extent.
    /// Nil when the screen has no such divider or no room for both minimums.
    public func ratio(of split: SplitID) -> ClosedRange<Double>? {
        guard let divider = geometry.dividers.first(where: { $0.id == split }) else { return nil }
        let horizontal = divider.axis == .horizontal
        let available = Double((horizontal ? divider.container.width : divider.container.height)
            - (horizontal ? divider.frame.width : divider.frame.height))
        guard available > 0, Double(divider.minimumA + divider.minimumB) <= available else { return nil }
        let lower = Double(divider.minimumA) / available, upper = (available - Double(divider.minimumB)) / available
        return lower <= upper ? lower...upper : nil
    }

    /// The width fractions of a scrolling `column` the strip shows as different widths: from the fraction
    /// whose frame is the column's minimum width up. Nil for a docked column or a screen with no strip size.
    public func width(of column: LayoutColumn) -> ClosedRange<Double>? {
        guard geometry.isColumns, column.dock == nil, geometry.stripWidth > 0 else { return nil }
        let lower = ColumnStripGeometry.fraction(forPixelWidth: column.minimumSize(style: style).width,
                                                 viewportWidth: geometry.stripWidth, gap: style.stripGap)
        return lower...max(lower, ColumnWidthPreset.widthRange.upperBound)
    }

    /// The widths of two neighbor strip columns after a keyboard press moves the divider between them by `delta` (a
    /// share of the strip; right is positive): `left` takes what `right` gives, or gives what it takes, so the columns
    /// after them and the strip stay where they are (the trade of an Option-drag, ``StripStart/trading(_:to:)``). The
    /// move is whole device pixels, so both widths round the same way and neither outer edge moves by a pixel. It stops
    /// where a column reaches its minimum or the widest share, and where the divider would leave the part of the strip
    /// the window shows (``stripOffset``): past it the press would move nothing a person sees. Each column counts from
    /// the width it shows (a stored width below its minimum shows at the minimum). Nil when nothing would move.
    public func trade(_ left: LayoutColumn, _ right: LayoutColumn, by delta: Double) -> (left: Double, right: Double)? {
        guard geometry.isColumns, let leftFrame = geometry.columns[left.id], let rightFrame = geometry.columns[right.id],
              case let unit = geometry.stripWidth - style.stripGap, unit > 0, delta != 0 else { return nil }
        let range = ColumnWidthPreset.widthRange
        func floor(_ column: LayoutColumn) -> Double {
            max(range.lowerBound, ColumnStripGeometry.fraction(forPixelWidth: column.minimumSize(style: style).width,
                                                               viewportWidth: geometry.stripWidth, gap: style.stripGap))
        }
        let shownLeft = min(max(left.width, floor(left)), range.upperBound)
        let shownRight = min(max(right.width, floor(right)), range.upperBound)
        // How far the divider may go, in points: right until a column reaches a bound, left the same.
        var most = CGFloat(min(range.upperBound - shownLeft, shownRight - floor(right))) * unit
        var least = -CGFloat(min(shownLeft - floor(left), range.upperBound - shownRight)) * unit
        if let stripOffset {
            let leading = max(0, geometry.uncoveredMinX - geometry.stripMinX)
            let trailing = max(0, geometry.stripMinX + geometry.stripWidth - geometry.uncoveredMaxX)
            most = min(most, stripOffset + geometry.stripWidth - trailing - rightFrame.minX)
            least = max(least, stripOffset + leading - leftFrame.maxX)
        }
        // Toward the arrow only, in whole pixels: the step to the nearest one, the room to the last one inside it
        // (`edgeTolerance` of a pixel of float slack), so a press never passes a bound.
        let pixel = scale > 0 ? scale : 1
        let room = max(0, delta > 0 ? most : -least)
        let pixels = min((abs(CGFloat(delta)) * unit * pixel).rounded(), (room * pixel + ColumnStripGeometry.edgeTolerance).rounded(.down))
        guard pixels > 0 else { return nil }
        let share = Double((delta > 0 ? pixels : -pixels) / pixel / unit)
        return (min(max(shownLeft + share, range.lowerBound), range.upperBound), min(max(shownRight - share, range.lowerBound), range.upperBound))
    }

    /// Every row height of `column` after a keyboard press moves the row edge next to `pane`'s row by `delta`
    /// (a share of the column's height; down is positive): the edge below that row, or above it for the last row.
    /// The press trades whole permille between the two rows (or, in a scrolling stack, sizes the upper row alone),
    /// the exact inverse of ``RowStackGeometry/compute``'s placement, so each press moves the edge by the same
    /// `(height + gap) * delta` points, snapped once to the pixel grid. Each row keeps 100 permille and the height its
    /// tree needs; a press at that limit is nil (nothing moves).
    public func rowHeights(moving pane: PaneID, in column: LayoutColumn, by delta: Double) -> [RowHeight]? {
        guard column.hasRows, let stack = geometry.rowStacks[column.id],
              let index = column.rows.firstIndex(where: { $0.root.contains(pane) }) else { return nil }
        let upper = index + 1 < column.rows.count ? index : index - 1
        guard upper >= 0 else { return nil }
        let rows = column.rows, sum = rows.reduce(0) { $0 + max($1.height, 1) }
        let fills = !style.rowsEnabled || sum <= 1000
        // Permille as placed: a filled stack scales every row by 1000 / sum.
        let scale = fills && sum > 0 ? Double(sum) / 1000 : 1
        /// The largest stored permille at which `row` still shows at its minimum height on this screen's pixel grid
        /// (as `RowStackGeometry.compute` places it: the placed height rounded to a pixel, held at the minimum rounded
        /// up to one): below it nothing moves, above it the edge moves. Searched from the exact estimate; a few steps.
        func floor(_ row: LayoutRow) -> Int {
            let minimum = SplitGeometry.ceilToPixel(SplitGeometry.minimumSize(of: row.root, style: style).height, scale: self.scale)
            func shown(_ stored: Int) -> CGFloat {
                SplitGeometry.roundToPixel(RowStackGeometry.pixelHeight(permille: Double(stored) / scale, columnHeight: stack.frame.height,
                                                                         gap: stack.gap), scale: self.scale)
            }
            let range = LayoutRow.heightRange
            let exact = Double((minimum + stack.gap) / (stack.frame.height + stack.gap)) * 1000 * scale
            var stored = min(max(Int(exact.rounded(.down)), range.lowerBound), range.upperBound)
            while stored > range.lowerBound, shown(stored) > minimum { stored -= 1 }
            while stored < range.upperBound, shown(stored + 1) <= minimum { stored += 1 }
            return stored
        }
        let step = Int((delta * 1000 * scale).rounded())
        guard step != 0 else { return nil }
        var heights = rows.map { RowHeight(row: $0.id, height: $0.height) }
        let range = LayoutRow.heightRange
        // The upper row's permille where it shows: a row stored below what its panes need shows at that minimum.
        let shownUpper = max(rows[upper].height, floor(rows[upper]))
        /// From where the row shows, one step toward `next`, inside `low...high`; nil when nothing would move, so a
        /// press never moves the edge the wrong way or sends a height the model refuses.
        /// Each direction checks only its own bound: Up (shrinking the upper row) stops at `low`, Down at `high`. Where
        /// the two rows' minimums cannot both fit (`low > high`), Up can still bring the upper row to its minimum (the
        /// lower row only grows).
        func stepped(low: Int, high: Int) -> Int? {
            if step > 0 {
                let next = min(shownUpper + step, high)
                return next > shownUpper ? next : nil
            }
            let next = max(shownUpper + step, low)
            return next < shownUpper ? next : nil
        }
        if fills {
            let pair = rows[upper].height + rows[upper + 1].height
            // Both rows stay in 100...1000 (setRowHeights refuses others) and keep their minimums.
            guard let next = stepped(low: max(floor(rows[upper]), pair - range.upperBound),
                                     high: min(pair - floor(rows[upper + 1]), range.upperBound)) else { return nil }
            heights[upper].height = next
            heights[upper + 1].height = pair - next
        } else {
            // A scrolling stack: the upper row alone, and never below the sum that fills the column (there the stack
            // places rows in proportion, a different edge): the press that reaches it is a part step.
            let rest = sum - rows[upper].height
            guard let next = stepped(low: max(floor(rows[upper]), 1000 - rest), high: range.upperBound) else { return nil }
            heights[upper].height = next
        }
        return heights
    }
}
