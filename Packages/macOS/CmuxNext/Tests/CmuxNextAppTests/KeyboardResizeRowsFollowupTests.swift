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
        // Rows whose minimum (a stack of n panes) sits between two permille: stored at the rounded permille + 1.
        for n in 1...6 {
            let stack = (1..<n).reversed().reduce(SplitNode.leaf(PaneID("q\(n)"))) { tail, i in
                .split(SplitID("s\(i)"), axis: .vertical, ratio: 0.5, a: .leaf(PaneID("q\(i)")), b: tail)
            }
            let upperRow = SplitNode.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: stack)
            let geometry = ScreenGeometry.compute(Self.layout([500, 500], rows: [upperRow, .leaf("p2")]), viewport: Self.viewport, style: Self.style)
            let stackGeometry = geometry.rowStacks["c0"]!
            let minimum = SplitGeometry.minimumSize(of: upperRow, style: Self.style).height
            let rounded = RowStackGeometry.permille(forPixelHeight: minimum, columnHeight: stackGeometry.frame.height, gap: stackGeometry.gap)
            let start = Self.layout([rounded + 1, 1000 - rounded - 1], rows: [upperRow, .leaf("p2")])
            if let heights = Self.change(.up, "p1", start) {
                let before = Self.edges(start), after = Self.edges(start.settingRowHeights(heights, for: "c0"))
                #expect(after[0] < before[0], "n=\(n): Up sent \(heights.map(\.height)) and the edge stayed at \(before[0])")
            }
        }
    }
}
