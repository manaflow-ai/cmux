import CmuxNextBridge
import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// RESIZE KEYS K4 (cmux-ad 2026-11-02, P0 "pixel perfect ctrl shift hjkl"; film rk-rows on feat 507438d and the dogfood
/// source): in a column of two rows (rows-v1, New Row), Ctrl-Shift-J/K and Ctrl-Cmd-Down/Up on the upper row moved
/// nothing. `PaneResize.change` looked for a vertical split in the row's own tree and then for a column dock band, and
/// found neither: a row edge was not a key resize target. A press must move the edge next to the pane's row one whole
/// step (5 % of the column height), or nothing at a row's minimum.
struct KeyboardResizeRowsTests {
    static let viewport = CGSize(width: 1153, height: 857)

    static var style: LayoutStyle {
        var style = LayoutStyle()
        style.minimumPaneContentSize = CGSize(width: 200, height: 64)
        style.rowsEnabled = true
        return style
    }

    static let start = ScreenLayout.columns([
        LayoutColumn(id: "c0", width: 1, root: .split("compat", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                     rows: [LayoutRow(id: "r1", height: 500, root: .leaf("p1")), LayoutRow(id: "r2", height: 500, root: .leaf("p2"))]),
    ])

    /// The row edge's y after each press of `direction` on `pane` (nil: the press changed nothing).
    static func edges(_ direction: LayoutDirection, _ count: Int, on pane: PaneID) -> [CGFloat?] {
        var layout = start, out: [CGFloat?] = []
        for _ in 0..<count {
            let geometry = ScreenGeometry.compute(layout, viewport: viewport, style: style)
            switch PaneResize.change(for: pane, direction: direction, in: layout, shown: ShownResizeRange(geometry: geometry, style: style)) {
            case .rowHeights(let column, let heights)?:
                layout = layout.settingRowHeights(heights, for: column)
                out.append(ScreenGeometry.compute(layout, viewport: viewport, style: style).rowStacks["c0"]?.rows.first?.frame.maxY)
            case nil: out.append(nil)
            default: Issue.record("a row press made another change"); out.append(nil)
            }
        }
        return out
    }

    @Test func downAndUpMoveTheRowEdgeOneWholeStepFromEitherRow() throws {
        let stack = try #require(ScreenGeometry.compute(Self.start, viewport: Self.viewport, style: Self.style).rowStacks["c0"])
        let base = try #require(stack.rows.first?.frame.maxY)
        let step = (stack.frame.height + stack.gap) * CGFloat(PaneResize.step)
        for (pane, direction, sign) in [("p1", LayoutDirection.down, 1.0), ("p1", .up, -1.0), ("p2", .down, 1.0), ("p2", .up, -1.0)] as [(PaneID, LayoutDirection, CGFloat)] {
            let moved = Self.edges(direction, 3, on: pane)
            var last = base
            for edge in moved {
                let edge = try #require(edge, "\(pane) \(direction): a press moved nothing (\(moved))")
                #expect(abs((edge - last) - sign * step) <= 1, "\(pane) \(direction): step \(edge - last), want \(sign * step)")
                last = edge
            }
        }
    }

    @Test func aPressAtARowMinimumChangesNothing() {
        let moved = Self.edges(.up, 30, on: "p1")
        let firstStop = moved.firstIndex(of: nil)
        #expect(firstStop != nil, "the edge never stopped: \(moved)")
        if let firstStop { #expect(moved[firstStop...].allSatisfy { $0 == nil }, "a press after the minimum moved: \(moved)") }
    }
}
