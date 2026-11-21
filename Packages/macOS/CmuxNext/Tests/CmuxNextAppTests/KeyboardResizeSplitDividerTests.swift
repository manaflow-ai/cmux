import CmuxNextBridge
import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// PANE KEYS, splits (Lawrence 2026-11-11: "ctrl shift hl behavior is unintuitive when i'm in a column, i think it sizes
/// things the wrong way?? like inside a single column?"; plans/cmux-next/pane-keys.md): inside a screen or a column, a
/// split's divider moves in the arrow's direction, as tmux, Ghostty and the divider a person sees suggest. Ctrl-Shift-H
/// moves the nearest side-by-side divider around the focused pane left, L moves it right; K / J move the nearest stacked
/// divider up / down. H / L never touch a stacked split and K / J never touch a side-by-side one. A divider at its limit
/// refuses the press: the key never falls back to another edge.
///
/// Before (2026-11-08, grow / shrink): Ctrl-Shift-H on the right pane of a split moved the divider right (the pane got
/// narrower), the opposite of the arrow.
nonisolated struct KeyboardResizeSplitDividerTests {
    static let viewport = CGSize(width: 1200, height: 800)

    static var style: LayoutStyle {
        var style = LayoutStyle()
        style.minimumPaneContentSize = CGSize(width: 120, height: 64)
        style.rowsEnabled = true
        return style
    }

    static func split(_ axis: SplitAxis, _ a: SplitNode, _ b: SplitNode, id: String = "s", ratio: Double = 0.5) -> SplitNode {
        .split(SplitID(id), axis: axis, ratio: ratio, a: a, b: b)
    }

    static func column(_ id: String, _ width: Double, _ root: SplitNode) -> LayoutColumn {
        LayoutColumn(id: ColumnID(id), width: width, root: root)
    }

    static func change(_ pane: PaneID, _ direction: LayoutDirection, _ layout: ScreenLayout) -> PaneResize.Change? {
        let geometry = ScreenGeometry.compute(layout, viewport: viewport, style: style)
        return PaneResize.change(for: pane, direction: direction, in: layout, shown: ShownResizeRange(geometry: geometry, style: style))
    }

    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let layout: ScreenLayout
        let pane: PaneID
        let direction: LayoutDirection
        /// The split whose divider must move, and whether its ratio grows (divider right / down).
        let split: String
        let grows: Bool
        var testDescription: String { name }
    }

    static let pair = split(.horizontal, .leaf("a"), .leaf("b"))
    static let stack = split(.vertical, .leaf("a"), .leaf("b"))

    static let cases: [Case] = [
        // The reported layout: one column holding a side-by-side split, focus in the right pane.
        Case(name: "one column split, right pane, H", layout: .columns([column("c0", 1, pair)]), pane: "b", direction: .left, split: "s", grows: false),
        Case(name: "one column split, right pane, L", layout: .columns([column("c0", 1, pair)]), pane: "b", direction: .right, split: "s", grows: true),
        Case(name: "one column split, left pane, H", layout: .columns([column("c0", 1, pair)]), pane: "a", direction: .left, split: "s", grows: false),
        Case(name: "one column split, left pane, L", layout: .columns([column("c0", 1, pair)]), pane: "a", direction: .right, split: "s", grows: true),
        Case(name: "split screen, right pane, H", layout: .splits(pair), pane: "b", direction: .left, split: "s", grows: false),
        Case(name: "split screen, right pane, L", layout: .splits(pair), pane: "b", direction: .right, split: "s", grows: true),
        // Nested columns: the right pane of a middle column's split moves the inner divider, not the column's edge.
        Case(name: "middle column split, right pane, L",
             layout: .columns([column("c0", 0.4, pair), column("c1", 0.4, .leaf("p1"))]), pane: "b", direction: .right, split: "s", grows: true),
        Case(name: "middle column split, right pane, H",
             layout: .columns([column("c0", 0.4, pair), column("c1", 0.4, .leaf("p1"))]), pane: "b", direction: .left, split: "s", grows: false),
        Case(name: "last column split, right pane, H",
             layout: .columns([column("c0", 0.4, .leaf("p0")), column("c1", 0.6, pair)]), pane: "b", direction: .left, split: "s", grows: false),
        // A side-by-side split inside a stacked column: H / L take the side-by-side one, however deep.
        Case(name: "stack over a pair, right pane, H",
             layout: .columns([column("c0", 1, split(.vertical, .leaf("top"), pair, id: "v"))]), pane: "b", direction: .left, split: "s", grows: false),
        // Middle of three: the nearest divider (the inner split's), in the arrow's direction both ways.
        Case(name: "middle of three, H", layout: .splits(split(.horizontal, .leaf("a"), split(.horizontal, .leaf("b"), .leaf("c"), id: "t"))),
             pane: "b", direction: .left, split: "t", grows: false),
        Case(name: "middle of three, L", layout: .splits(split(.horizontal, .leaf("a"), split(.horizontal, .leaf("b"), .leaf("c"), id: "t"))),
             pane: "b", direction: .right, split: "t", grows: true),
        // J / K on stacked splits, the same rule.
        Case(name: "stacked column, bottom pane, K", layout: .columns([column("c0", 1, stack)]), pane: "b", direction: .up, split: "s", grows: false),
        Case(name: "stacked column, bottom pane, J", layout: .columns([column("c0", 1, stack)]), pane: "b", direction: .down, split: "s", grows: true),
        Case(name: "stacked column, top pane, K", layout: .columns([column("c0", 1, stack)]), pane: "a", direction: .up, split: "s", grows: false),
    ]

    /// The press moves the nearest matching-axis divider in the arrow's direction.
    @Test(arguments: cases)
    func theDividerMovesInTheArrowsDirection(_ row: Case) throws {
        let change = try #require(Self.change(row.pane, row.direction, row.layout), "the press moved nothing")
        guard case let .splitRatio(id, ratio) = change else {
            Issue.record("the press made \(change), not a move of split \(row.split)")
            return
        }
        #expect(id == SplitID(row.split), "the press moved split \(id), not \(row.split)")
        #expect(row.grows ? ratio > 0.5 : ratio < 0.5, "the divider moved to \(ratio), against the arrow")
    }

    /// Inside a single stacked column, H / L never touch the column's stacked splits.
    @Test(arguments: [LayoutDirection.left, .right], ["a", "b"] as [PaneID])
    func leftAndRightNeverMoveAStackedSplit(_ direction: LayoutDirection, _ pane: PaneID) {
        let layouts: [ScreenLayout] = [.columns([Self.column("c0", 1, Self.stack)]), .splits(Self.stack),
                                       .columns([Self.column("c0", 0.5, Self.stack), Self.column("c1", 0.5, .leaf("p1"))])]
        for layout in layouts {
            if case .splitRatio(let id, _)? = Self.change(pane, direction, layout) {
                Issue.record("\(direction) on \(pane) moved stacked split \(id) in \(layout)")
            }
        }
    }

    /// A divider at its limit refuses the press: no fallback to the column's edge or another split.
    @Test func aDividerAtItsLimitRefusesThePress() {
        let atRight = Self.split(.horizontal, .leaf("a"), .leaf("b"), ratio: SplitRatio.range.upperBound)
        let layout = ScreenLayout.columns([Self.column("c0", 0.4, atRight), Self.column("c1", 0.4, .leaf("p1"))])
        #expect(Self.change("b", .right, layout) == nil)
        let atLeft = Self.split(.horizontal, .leaf("a"), .leaf("b"), ratio: SplitRatio.range.lowerBound)
        #expect(Self.change("a", .left, .columns([Self.column("c0", 0.4, atLeft), Self.column("c1", 0.4, .leaf("p1"))])) == nil)
    }

    /// Rows (rows-v1) read as stacked splits: Down moves the row edge down from either row, Up moves it up.
    @Test func rowEdgesMoveInTheArrowsDirection() throws {
        let rows = LayoutColumn(id: "c0", width: 1, root: Self.split(.vertical, .leaf("r1p"), .leaf("r2p"), id: "compat"),
                                rows: [LayoutRow(id: "r1", height: 500, root: .leaf("r1p")), LayoutRow(id: "r2", height: 500, root: .leaf("r2p"))])
        let layout = ScreenLayout.columns([rows])
        for (pane, direction, firstGrows) in [("r1p", LayoutDirection.down, true), ("r2p", .down, true), ("r1p", .up, false), ("r2p", .up, false)]
            as [(PaneID, LayoutDirection, Bool)] {
            guard case let .rowHeights(_, heights)? = Self.change(pane, direction, layout) else {
                Issue.record("\(direction) on \(pane) made no row change")
                continue
            }
            let first = try #require(heights.first).height
            #expect(firstGrows ? first > 500 : first < 500, "\(direction) on \(pane) set the upper row to \(first)")
        }
    }
}
