import CmuxNextBridge
import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// RESIZE KEYS K4, the review of #32471 (FIX FIRST at d5d5c04fcf0): row heights the screen does not show as stored.
/// - A row stored below the height its panes need shows at that minimum: a press must step from what shows, never move
///   the edge the wrong way or change the model with no motion (the review saw Down move an edge 168 pt UP).
/// - Rows off (`fits`) with heights summing above 1000 (New Row on a full-height row gives [1000, 1000]): a press must
///   never send heights outside 100...1000 (the model drops them and the key does nothing, with no refusal).
/// - A scrolling stack (sum above 1000) that a press brings to 1000 or less fills the column: no press may jump more than
///   one step there.
/// - A top or bottom dock with rows: up and down keep resizing the dock band, as before rows.
struct KeyboardResizeRowsEdgeCasesTests {
    static let viewport = CGSize(width: 1153, height: 857)

    static func style(rows: Bool = true) -> LayoutStyle {
        var style = LayoutStyle()
        style.minimumPaneContentSize = CGSize(width: 200, height: 64)
        style.rowsEnabled = rows
        return style
    }

    /// Panes split vertically one under the other: a row whose panes need one minimum height each.
    static func stack(_ panes: [PaneID]) -> SplitNode {
        panes.dropLast().reversed().reduce(SplitNode.leaf(panes[panes.count - 1])) { tail, pane in
            .split(SplitID(rawValue: "s-\(pane.rawValue)"), axis: .vertical, ratio: 0.5, a: .leaf(pane), b: tail)
        }
    }

    static func layout(_ heights: [Int], rows: [SplitNode], dock: DockColumn? = nil) -> ScreenLayout {
        let ids = (0..<heights.count).map { RowID(rawValue: "r\($0)") }
        let compat = rows.dropLast().enumerated().reversed().reduce(rows[rows.count - 1]) { tail, item in
            .split(SplitID(rawValue: "compat-\(item.offset)"), axis: .vertical, ratio: 0.5, a: item.element, b: tail)
        }
        return .columns([LayoutColumn(id: "c0", width: 1, root: compat, dock: dock,
                                      rows: zip(ids, zip(heights, rows)).map { LayoutRow(id: $0, height: $1.0, root: $1.1) })])
    }

    struct Press { var change: PaneResize.Change?; var before: CGFloat; var after: CGFloat }

    /// One press: the change, and the shown edge below the first row before and after it.
    static func press(_ direction: LayoutDirection, on pane: PaneID, _ layout: ScreenLayout, style: LayoutStyle) -> (Press, ScreenLayout) {
        let geometry = ScreenGeometry.compute(layout, viewport: viewport, style: style)
        let edge = { (g: ScreenGeometry) in g.rowStacks["c0"]?.rows.first?.frame.maxY ?? -1 }
        let change = PaneResize.change(for: pane, direction: direction, in: layout, shown: ShownResizeRange(geometry: geometry, style: style))
        var next = layout
        if case .rowHeights(let column, let heights)? = change { next = layout.settingRowHeights(heights, for: column) }
        return (Press(change: change, before: edge(geometry), after: edge(ScreenGeometry.compute(next, viewport: viewport, style: style))), next)
    }

    static func step(_ style: LayoutStyle, _ layout: ScreenLayout) -> CGFloat {
        let stack = ScreenGeometry.compute(layout, viewport: viewport, style: style).rowStacks["c0"]!
        return (stack.frame.height + stack.gap) * CGFloat(PaneResize.step)
    }

    @Test func anUpperRowStoredBelowItsMinimumStepsFromWhereItShows() {
        let style = Self.style()
        // p1 beside a stack of three: the row needs three panes' height, and p1 has no vertical split of its own (a split
        // in the pane's row wins over the row edge).
        let upperRow = SplitNode.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: Self.stack(["q1", "q2", "q3"]))
        let start = Self.layout([100, 900], rows: [upperRow, .leaf("p2")])
        let (up, _) = Self.press(.up, on: "p1", start, style: style)
        #expect(up.change == nil, "Up on a row at its minimum changed the model: \(String(describing: up.change))")
        let (down, _) = Self.press(.down, on: "p1", start, style: style)
        #expect(abs((down.after - down.before) - Self.step(style, start)) <= 1, "Down moved \(down.after - down.before), want one step")
    }

    @Test func aLowerRowBelowItsMinimumNeverMovesTheEdgeTheWrongWay() {
        let style = Self.style()
        let start = Self.layout([600, 400], rows: [.leaf("p1"), Self.stack(["p2", "q1", "q2", "q3", "q4", "q5"])])
        let (down, _) = Self.press(.down, on: "p1", start, style: style)
        #expect(down.change == nil || down.after - down.before > 0, "Down moved the edge up by \(down.before - down.after) pt")
        #expect(down.change == nil || down.after != down.before, "Down changed the model and moved nothing")
        let (up, _) = Self.press(.up, on: "p1", start, style: style)
        #expect(abs((up.after - up.before) + Self.step(style, start)) <= 1, "Up moved \(up.after - up.before), want minus one step")
    }

    @Test func rowsOffNeverSendsHeightsTheModelRefuses() {
        let style = Self.style(rows: false)
        let start = Self.layout([1000, 1000], rows: [.leaf("p1"), .leaf("p2")])
        for direction in [LayoutDirection.up, .down] {
            for pane: PaneID in ["p1", "p2"] {
                let (press, _) = Self.press(direction, on: pane, start, style: style)
                if case .rowHeights(_, let heights)? = press.change {
                    #expect(heights.allSatisfy { LayoutRow.heightRange.contains($0.height) }, "\(pane) \(direction): \(heights.map(\.height))")
                }
            }
        }
    }

    @Test func aScrollingStackNeverJumpsMoreThanOneStep() {
        let style = Self.style()
        var layout = Self.layout([700, 700], rows: [.leaf("p1"), .leaf("p2")])
        let step = Self.step(style, layout)
        for _ in 0..<12 {
            let (press, next) = Self.press(.up, on: "p1", layout, style: style)
            guard press.change != nil else { break }
            #expect(press.after - press.before < 0 && press.before - press.after <= step + 1,
                    "Up moved \(press.after - press.before), want at most one step up")
            layout = next
        }
    }

    @Test func aBandDockWithRowsStillResizesTheDock() {
        let style = Self.style()
        let dock = DockColumn(edge: .top, mode: .docked, role: nil, isPinned: false)
        // Below its widest extent (1.0), so Down can grow it.
        let start = ScreenLayout.columns([LayoutColumn(id: "c0", width: 0.4, root: .split("compat", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                                       dock: dock, rows: [LayoutRow(id: "r0", height: 500, root: .leaf("p1")),
                                                                          LayoutRow(id: "r1", height: 500, root: .leaf("p2"))])])
        let geometry = ScreenGeometry.compute(start, viewport: Self.viewport, style: style)
        let change = PaneResize.change(for: "p1", direction: .down, in: start, shown: ShownResizeRange(geometry: geometry, style: style))
        if case .columnWidth? = change {} else { Issue.record("Down on a top dock with rows made \(String(describing: change)), want the dock's extent") }
    }
}
