import CmuxNextBridge
import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// RESIZE KEYS K4 follow-ups from the re-review of #32471 (SHIP at 76e9d242628, notes A, B, C).
/// - A: a scrolling stack (sum above 1000) that one press brings to 1000 stops exactly there ([520, 500] -> [500, 500]).
/// - B: in three rows the middle row's press moves its lower edge; the top row stays.
/// - C: the row minimum in permille rounds UP: a row stored one permille above its minimum must refuse Up or move the
///   edge, never change the model with no motion (a dead press).
struct KeyboardResizeRowsFollowupTests {
    static let viewport = CGSize(width: 1153, height: 857)
    static var style: LayoutStyle {
        var style = LayoutStyle()
        style.minimumPaneContentSize = CGSize(width: 200, height: 64)
        style.rowsEnabled = true
        return style
    }

    static func layout(_ heights: [Int], rows: [SplitNode]) -> ScreenLayout {
        let compat = rows.dropLast().enumerated().reversed().reduce(rows[rows.count - 1]) { tail, item in
            .split(SplitID("compat-\(item.offset)"), axis: .vertical, ratio: 0.5, a: item.element, b: tail)
        }
        return .columns([LayoutColumn(id: "c0", width: 1, root: compat,
                                      rows: zip(heights, rows).enumerated().map { LayoutRow(id: RowID("r\($0.offset)"), height: $0.element.0, root: $0.element.1) })])
    }

    static func change(_ direction: LayoutDirection, _ pane: PaneID, _ layout: ScreenLayout) -> [RowHeight]? {
        let geometry = ScreenGeometry.compute(layout, viewport: viewport, style: style)
        guard case .rowHeights(_, let heights)? = PaneResize.change(for: pane, direction: direction, in: layout,
                                                                    shown: ShownResizeRange(geometry: geometry, style: style)) else { return nil }
        return heights
    }

    static func edges(_ layout: ScreenLayout) -> [CGFloat] {
        ScreenGeometry.compute(layout, viewport: viewport, style: style).rowStacks["c0"]?.rows.map(\.frame.maxY) ?? []
    }

    @Test func aScrollingStackStopsExactlyWhereItFillsTheColumn() {
        let start = Self.layout([520, 500], rows: [.leaf("p1"), .leaf("p2")])
        #expect(Self.change(.up, "p1", start)?.map(\.height) == [500, 500])
    }

    @Test func theMiddleOfThreeRowsMovesItsLowerEdge() throws {
        let start = Self.layout([300, 400, 300], rows: [.leaf("p1"), .leaf("p2"), .leaf("p3")])
        let heights = try #require(Self.change(.down, "p2", start))
        #expect(heights.map(\.height) == [300, 450, 250])
        let before = Self.edges(start), after = Self.edges(start.settingRowHeights(heights, for: "c0"))
        #expect(before[0] == after[0], "the top row moved")
        #expect(after[1] > before[1])
    }

    @Test func aRowOnePermilleAboveItsMinimumNeverTakesADeadPress() {
        // The minimum pane content height in quarter points from 64 to 400: many sit between two permille, where a floor
        // rounded to the nearest permille is half a permille low (the review counted 58 such heights at H 841).
        var checked = 0
        for quarter in 0...1344 {
            var style = Self.style
            style.minimumPaneContentSize.height = 64 + CGFloat(quarter) / 4
            let start0 = Self.layout([500, 500], rows: [.leaf("p1"), .leaf("p2")])
            guard let stack = ScreenGeometry.compute(start0, viewport: Self.viewport, style: style).rowStacks["c0"] else { continue }
            let minimum = SplitGeometry.minimumSize(of: .leaf("p1"), style: style).height
            let rounded = RowStackGeometry.permille(forPixelHeight: minimum, columnHeight: stack.frame.height, gap: stack.gap)
            guard rounded + 1 < 900 else { continue }
            let start = Self.layout([rounded + 1, 999 - rounded], rows: [.leaf("p1"), .leaf("p2")])
            let geometry = ScreenGeometry.compute(start, viewport: Self.viewport, style: style)
            guard case .rowHeights(let column, let heights)? = PaneResize.change(for: "p1", direction: .up, in: start,
                                                                                shown: ShownResizeRange(geometry: geometry, style: style)) else { continue }
            checked += 1
            let before = geometry.rowStacks["c0"]!.rows[0].frame.maxY
            let after = ScreenGeometry.compute(start.settingRowHeights(heights, for: column), viewport: Self.viewport, style: style)
                .rowStacks["c0"]!.rows[0].frame.maxY
            #expect(after < before, "content height \(style.minimumPaneContentSize.height): Up sent \(heights.map(\.height)) and the edge stayed at \(before)")
        }
        #expect(checked > 0)
    }
}
