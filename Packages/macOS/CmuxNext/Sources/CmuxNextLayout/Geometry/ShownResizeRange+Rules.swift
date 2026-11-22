import CCmuxLayoutReducerFFI
import CoreGraphics

// The rules of ``ShownResizeRange`` run by cmux-layout-reducer (`shown_resize`) over the app FFI's typed
// `cmux_shown_resize_*` calls: one in-process call per key press, no JSON, no allocation (the dock and row arrays
// are passed in place). Nothing here decides: these map the values the wrapper read from the geometry into the C
// structs and the answer back. The rules and their tests are in the crate (`src/shown_resize.rs`,
// `tests/shown_resize_corpus.rs`); `ShownResizeRangeCorpusTests` checks these calls against the same corpus the
// Swift rules recorded before they moved.
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

    private static func bounds(_ call: (UnsafeMutablePointer<CmuxShownResizeBounds>) -> Int32) -> Bounds? {
        var out = CmuxShownResizeBounds()
        return call(&out) == 1 ? Bounds(lower: out.lower, upper: out.upper) : nil
    }

    static func ratioRule(containerExtent: CGFloat, dividerExtent: CGFloat, minimumA: CGFloat, minimumB: CGFloat) -> Bounds? {
        bounds { cmux_shown_resize_ratio(Double(containerExtent), Double(dividerExtent), Double(minimumA), Double(minimumB), $0) }
    }

    static func columnWidthRule(isColumns: Bool, isDocked: Bool, stripWidth: CGFloat, minimumWidth: CGFloat, gap: CGFloat) -> Bounds? {
        bounds {
            cmux_shown_resize_column_width(isColumns ? 1 : 0, isDocked ? 1 : 0, Double(stripWidth), Double(minimumWidth), Double(gap), $0)
        }
    }

    static func dockWidthRule(_ all: [DockSide], viewportWidth width: CGFloat, gap: CGFloat, minimumWidth: CGFloat) -> Bounds? {
        let docks = all.map {
            CmuxShownResizeDock(width: Double($0.width), is_target: $0.isTarget ? 1 : 0, is_band: $0.isBand ? 1 : 0,
                                is_docked: $0.isDocked ? 1 : 0, reserved: (0, 0, 0, 0, 0))
        }
        return docks.withUnsafeBufferPointer { docks in
            bounds { cmux_shown_resize_dock_width(docks.baseAddress, docks.count, Double(width), Double(gap), Double(minimumWidth), $0) }
        }
    }

    static func tradeRule(_ t: TradeInput) -> TradeCandidates? {
        var input = CmuxShownResizeTrade()
        input.strip_width = Double(t.stripWidth)
        input.gap = Double(t.gap)
        input.scale = Double(t.scale)
        input.delta = t.delta
        input.left_min_x = Double(t.leftMinX)
        input.left_max_x = Double(t.leftMaxX)
        input.left_width = Double(t.leftWidth)
        input.right_min_x = Double(t.rightMinX)
        input.right_max_x = Double(t.rightMaxX)
        input.right_width = Double(t.rightWidth)
        input.left_minimum_width = Double(t.leftMinimumWidth)
        input.right_minimum_width = Double(t.rightMinimumWidth)
        input.left_fraction = t.leftFraction
        input.right_fraction = t.rightFraction
        input.strip_offset = Double(t.stripOffset ?? 0)
        input.has_strip_offset = t.stripOffset == nil ? 0 : 1
        input.uncovered_min_x = Double(t.uncoveredMinX)
        input.uncovered_max_x = Double(t.uncoveredMaxX)
        input.strip_min_x = Double(t.stripMinX)
        input.is_columns = t.isColumns ? 1 : 0
        var out = CmuxShownResizeTradeAnswer()
        guard cmux_shown_resize_trade(&input, &out) == 1 else { return nil }
        return TradeCandidates(move: CGFloat(out.move_points), first: (out.first_left, out.first_right),
                               second: (out.second_left, out.second_right))
    }

    static func rowHeightsRule(_ r: RowInput) -> [Int]? {
        guard r.paneRow >= 0, r.minimumHeights.count == r.heights.count else { return nil }
        let heights = r.heights.map(Int64.init)
        let minimums = r.minimumHeights.map(Double.init)
        var out = [Int64](repeating: 0, count: heights.count)
        let code = heights.withUnsafeBufferPointer { heights in
            minimums.withUnsafeBufferPointer { minimums in
                out.withUnsafeMutableBufferPointer { out in
                    var input = CmuxShownResizeRows(
                        heights: heights.baseAddress, minimum_heights: minimums.baseAddress, count: heights.count,
                        pane_row: r.paneRow, column_height: Double(r.columnHeight), gap: Double(r.gap), scale: Double(r.scale),
                        delta: r.delta, rows_enabled: r.rowsEnabled ? 1 : 0, reserved: (0, 0, 0, 0, 0, 0, 0))
                    return cmux_shown_resize_row_heights(&input, out.baseAddress, out.count)
                }
            }
        }
        return code == 1 ? out.map(Int.init) : nil
    }
}
