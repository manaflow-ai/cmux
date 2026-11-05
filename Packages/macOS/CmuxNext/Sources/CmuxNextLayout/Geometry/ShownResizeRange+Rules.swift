import CoreGraphics

// The rules of ``ShownResizeRange`` over plain numbers: the screen's geometry goes in as the values these rules read,
// so the same rules run in cmux-layout-reducer (`shown_resize`) over the same inputs. The fixture
// `cmux-tui/crates/cmux-layout-reducer/tests/data/shown_resize_corpus.txt` holds their answers for a seeded corpus;
// `ShownResizeRangeCorpusTests` (Swift) and `shown_resize_corpus` (Rust) both check against it, so the Rust port is
// proven equal before the app calls it (RUST MIGRATION, swift-logic owner, step A).
nonisolated extension ShownResizeRange {
    /// A closed range as two numbers (the shape the C ABI returns).
    struct Bounds: Equatable {
        var lower: Double
        var upper: Double
    }

    /// One side dock as ``dockWidth(of:)`` reads it.
    struct DockSide: Equatable {
        /// The column the press resizes.
        var isTarget: Bool
        /// A top or bottom band (not a side dock).
        var isBand: Bool
        var isDocked: Bool
        var width: CGFloat
    }

    /// What a keyboard trade between two neighbor strip columns reads.
    struct TradeInput: Equatable {
        var isColumns: Bool
        var stripWidth: CGFloat
        var gap: CGFloat
        var scale: CGFloat
        var delta: Double
        var leftMinX: CGFloat
        var leftMaxX: CGFloat
        var leftWidth: CGFloat
        var rightMinX: CGFloat
        var rightMaxX: CGFloat
        var rightWidth: CGFloat
        var leftMinimumWidth: CGFloat
        var rightMinimumWidth: CGFloat
        var leftFraction: Double
        var rightFraction: Double
        var stripOffset: CGFloat?
        var uncoveredMinX: CGFloat
        var uncoveredMaxX: CGFloat
        var stripMinX: CGFloat
    }

    /// The divider move of a trade and its two candidate width pairs, in the order the caller tries them.
    struct TradeCandidates: Equatable {
        var move: CGFloat
        var first: (left: Double, right: Double)
        var second: (left: Double, right: Double)

        static func == (a: Self, b: Self) -> Bool {
            a.move == b.move && a.first == b.first && a.second == b.second
        }
    }

    /// What a keyboard press on a column's row edge reads.
    struct RowInput: Equatable {
        /// Every row's stored permille, top to bottom.
        var heights: [Int]
        /// Every row's minimum height in points (its split tree's), top to bottom.
        var minimumHeights: [CGFloat]
        /// The row that holds the pane the press is on.
        var paneRow: Int
        var rowsEnabled: Bool
        var columnHeight: CGFloat
        var gap: CGFloat
        var scale: CGFloat
        var delta: Double
    }

    static func ratioRule(containerExtent: CGFloat, dividerExtent: CGFloat, minimumA: CGFloat, minimumB: CGFloat) -> Bounds? {
        let available = Double(containerExtent - dividerExtent)
        guard available > 0, Double(minimumA + minimumB) <= available else { return nil }
        let lower = Double(minimumA) / available, upper = (available - Double(minimumB)) / available
        return lower <= upper ? Bounds(lower: lower, upper: upper) : nil
    }

    static func columnWidthRule(isColumns: Bool, isDocked: Bool, stripWidth: CGFloat, minimumWidth: CGFloat, gap: CGFloat) -> Bounds? {
        guard isColumns, !isDocked, stripWidth > 0 else { return nil }
        let lower = ColumnStripGeometry.fraction(forPixelWidth: minimumWidth, viewportWidth: stripWidth, gap: gap)
        return Bounds(lower: lower, upper: max(lower, ColumnWidthPreset.widthRange.upperBound))
    }

    static func dockWidthRule(_ all: [DockSide], viewportWidth width: CGFloat, gap: CGFloat, minimumWidth: CGFloat) -> Bounds? {
        let sides = all.filter { !$0.isBand }
        guard let entry = sides.first(where: \.isTarget) else { return nil }
        var widest = max(1, width * (sides.count == 2 ? DockStripGeometry.maxShareBoth : DockStripGeometry.maxShare))
        if entry.isDocked {
            let others = sides.filter { !$0.isTarget && $0.isDocked }
            let room = width - min(DockStripGeometry.minimumStripWidth, width / 2) - gap * CGFloat(others.count + 1)
            widest = min(widest, room - others.reduce(0) { $0 + $1.width })
        }
        let lower = ColumnStripGeometry.fraction(forPixelWidth: minimumWidth, viewportWidth: width, gap: gap)
        let upper = ColumnStripGeometry.fraction(forPixelWidth: widest, viewportWidth: width, gap: gap)
        return Bounds(lower: lower, upper: max(lower, upper))
    }

    static func tradeRule(_ input: TradeInput) -> TradeCandidates? {
        let strip = input.stripWidth, gap = input.gap, scale = input.scale, delta = input.delta
        guard input.isColumns, case let unit = strip - gap, unit > 0, delta != 0 else { return nil }
        let range = ColumnWidthPreset.widthRange
        let pixel = scale > 0 ? scale : 1
        let widest = max(1, strip - gap * 2)
        func ideal(_ fraction: Double) -> CGFloat { ColumnStripGeometry.pixelWidth(fraction: fraction, viewportWidth: strip, gap: gap) }
        /// The narrowest width a column shows: its minimum rounded up to a pixel, and never below the narrowest share.
        func floor(_ minimum: CGFloat) -> CGFloat {
            max(SplitGeometry.ceilToPixel(min(minimum, widest), scale: scale),
                SplitGeometry.ceilToPixel(ideal(range.lowerBound), scale: scale))
        }
        // How far the divider may go, in points: right until a column reaches a bound, left the same.
        var most = min(widest - input.leftWidth, input.rightWidth - floor(input.rightMinimumWidth))
        var least = -min(input.leftWidth - floor(input.leftMinimumWidth), widest - input.rightWidth)
        if let stripOffset = input.stripOffset {
            let leading = max(0, input.uncoveredMinX - input.stripMinX)
            let trailing = max(0, input.stripMinX + strip - input.uncoveredMaxX)
            most = min(most, stripOffset + strip - trailing - input.rightMinX)
            least = max(least, stripOffset + leading - input.leftMaxX)
        }
        // Toward the arrow only, in whole pixels: the step to the nearest one, the room to the last one inside it
        // (`edgeTolerance` of a pixel of float slack), so a press never passes a bound.
        let room = max(0, delta > 0 ? most : -least)
        let pixels = min((abs(CGFloat(delta)) * unit * pixel).rounded(), (room * pixel + ColumnStripGeometry.edgeTolerance).rounded(.down))
        guard pixels > 0 else { return nil }
        let move = (delta > 0 ? pixels : -pixels) / pixel
        let (leftShown, rightShown) = (input.leftWidth + move, input.rightWidth - move)
        // The ideal widths that show those: the pair's ideal sum kept, both the same way from their pixels; else (a pair
        // whose ideal widths are both on a tie, where that way is the tie itself) the shown widths themselves.
        let (leftIdeal, rightIdeal) = (ideal(input.leftFraction), ideal(input.rightFraction))
        let shift = (leftShown - leftIdeal + rightIdeal - rightShown) / 2
        /// The width `width` points shows as, as the daemon keeps it (`f32`, cmux-tui `LayoutColumn.width`).
        func kept(_ width: CGFloat) -> Double {
            Double(Float(ColumnStripGeometry.fraction(forPixelWidth: width, viewportWidth: strip, gap: gap)))
        }
        return TradeCandidates(move: move, first: (kept(leftIdeal + shift), kept(rightIdeal - shift)),
                               second: (kept(leftShown), kept(rightShown)))
    }

    static func rowHeightsRule(_ input: RowInput) -> [Int]? {
        let rows = input.heights, index = input.paneRow
        guard index >= 0, index < rows.count, input.minimumHeights.count == rows.count else { return nil }
        let upper = index + 1 < rows.count ? index : index - 1
        guard upper >= 0 else { return nil }
        let sum = rows.reduce(0) { $0 + max($1, 1) }
        let fills = !input.rowsEnabled || sum <= 1000
        // Permille as placed: a filled stack scales every row by 1000 / sum.
        let scale = fills && sum > 0 ? Double(sum) / 1000 : 1
        let pixelScale = input.scale, columnHeight = input.columnHeight, gap = input.gap
        /// The largest stored permille at which row `row` still shows at its minimum height on this screen's pixel grid
        /// (as `RowStackGeometry.compute` places it: the placed height rounded to a pixel, held at the minimum rounded
        /// up to one): below it nothing moves, above it the edge moves. Searched from the exact estimate; a few steps.
        func floor(_ row: Int) -> Int {
            let minimum = SplitGeometry.ceilToPixel(input.minimumHeights[row], scale: pixelScale)
            func shown(_ stored: Int) -> CGFloat {
                SplitGeometry.roundToPixel(RowStackGeometry.pixelHeight(permille: Double(stored) / scale, columnHeight: columnHeight,
                                                                         gap: gap), scale: pixelScale)
            }
            let range = LayoutRow.heightRange
            let exact = Double((minimum + gap) / (columnHeight + gap)) * 1000 * scale
            var stored = min(max(Int(exact.rounded(.down)), range.lowerBound), range.upperBound)
            while stored > range.lowerBound, shown(stored) > minimum { stored -= 1 }
            while stored < range.upperBound, shown(stored + 1) <= minimum { stored += 1 }
            return stored
        }
        let step = Int((input.delta * 1000 * scale).rounded())
        guard step != 0 else { return nil }
        var heights = rows
        let range = LayoutRow.heightRange
        // The upper row's permille where it shows: a row stored below what its panes need shows at that minimum.
        let shownUpper = max(rows[upper], floor(upper))
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
            let pair = rows[upper] + rows[upper + 1]
            // Both rows stay in 100...1000 (setRowHeights refuses others) and keep their minimums.
            guard let next = stepped(low: max(floor(upper), pair - range.upperBound),
                                     high: min(pair - floor(upper + 1), range.upperBound)) else { return nil }
            heights[upper] = next
            heights[upper + 1] = pair - next
        } else {
            // A scrolling stack: the upper row alone, and never below the sum that fills the column (there the stack
            // places rows in proportion, a different edge): the press that reaches it is a part step.
            let rest = sum - rows[upper]
            guard let next = stepped(low: max(floor(upper), 1000 - rest), high: range.upperBound) else { return nil }
            heights[upper] = next
        }
        return heights
    }
}
