import CmuxNextBridge
import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// RESIZE KEYS (cmux-ad 2026-11-02, P0: "still dont have pixel perfect ctrl shift hjkl for resizing"). Film rk-limit
/// (feat 507438d, handoff/resize-videos/rk-feat507-g2-120x2): Ctrl-Shift-H twelve times on p1 of p0 | p1 moved the
/// divider 57.5 pt per press until p0 reached its minimum width, then presses 8 to 12 moved nothing, and of the four
/// Ctrl-Shift-L after them the first two moved nothing and the third 30.5 pt. The key changed the ratio down to
/// `SplitRatio.range` (0.05) where the minimum pane width holds the divider long before: dead presses there and on the
/// way back, and a part step. The same at the maximum, and for a strip column against its minimum width.
///
/// Every press must move the divider one equal step, or (only the press that reaches the limit) less, or change nothing
/// at all; the first press back from a limit is a whole step.
struct KeyboardResizeShownLimitTests {
    static let viewport = CGSize(width: 1153, height: 857)

    static var style: LayoutStyle {
        var style = LayoutStyle()
        style.minimumPaneContentSize = CGSize(width: 200, height: 64)
        return style
    }

    /// One press on `pane`: the layout after it, or nil when the press changes nothing.
    static func press(_ direction: LayoutDirection, on pane: PaneID, in layout: ScreenLayout) -> ScreenLayout? {
        let shown = ShownResizeRange(geometry: ScreenGeometry.compute(layout, viewport: viewport, style: style), style: style)
        switch PaneResize.change(for: pane, direction: direction, in: layout, shown: shown) {
        case .splitRatio(let split, let ratio): return layout.settingRatio(ratio, for: split)
        case .columnWidth(let column, let width): return layout.settingWidth(width, for: column)
        case .columnTrade(let left, let leftWidth, let right, let rightWidth):
            return layout.settingWidth(leftWidth, for: left).settingWidth(rightWidth, for: right)
        case .rowHeights(let column, let heights): return layout.settingRowHeights(heights, for: column)
        case nil: return nil
        }
    }

    /// Presses `direction` `count` times; returns the shown edge after each press (nil: the press changed nothing)
    /// and the final layout.
    static func presses(_ direction: LayoutDirection, _ count: Int, on pane: PaneID, from layout: ScreenLayout,
                        edge: (ScreenGeometry) -> CGFloat) -> (edges: [CGFloat?], layout: ScreenLayout) {
        var layout = layout, edges: [CGFloat?] = []
        for _ in 0..<count {
            if let next = press(direction, on: pane, in: layout) {
                layout = next
                edges.append(edge(ScreenGeometry.compute(layout, viewport: viewport, style: style)))
            } else {
                edges.append(nil)
            }
        }
        return (edges, layout)
    }

    /// Each press's move from `start`: a press that changed the model must move the edge.
    static func moves(from start: CGFloat, _ edges: [CGFloat?]) -> [CGFloat?] {
        var last = start
        return edges.map { edge in
            guard let edge else { return nil }
            defer { last = edge }
            return edge - last
        }
    }

    static func check(towardLimit: [CGFloat?], back: [CGFloat?], step: CGFloat) {
        // No press changes the model without moving the edge (a dead press: the model and the daemon drift past
        // what the screen shows).
        #expect(!towardLimit.contains(0), "a press toward the limit changed the layout but moved nothing: \(towardLimit)")
        #expect(!back.contains(0), "a press back from the limit changed the layout but moved nothing: \(back)")
        // Toward the limit: whole steps, then at most one part step (the one that reaches it), then no change.
        let moved = towardLimit.compactMap { $0 }
        #expect(moved.dropLast().allSatisfy { abs(abs($0) - step) <= 1 }, "unequal steps toward the limit: \(moved)")
        #expect(towardLimit.firstIndex(of: nil).map { towardLimit[$0...].allSatisfy { $0 == nil } } ?? true,
                "a press after the limit moved again: \(towardLimit)")
        // Back: every press a whole step, the first included.
        #expect(back.allSatisfy { $0.map { abs(abs($0) - step) <= 1 } ?? false }, "the presses back are not whole steps: \(back)")
    }

    @Test func splitPressesStopAtTheMinimumPaneWidthAndComeBackAWholeStep() {
        let start = ScreenLayout.splits(.split("s", axis: .horizontal, ratio: 0.5, a: .leaf("p0"), b: .leaf("p1")))
        let divider: (ScreenGeometry) -> CGFloat = { $0.panes["p0"]?.maxX ?? -1 }
        let base = ScreenGeometry.compute(start, viewport: Self.viewport, style: Self.style)
        let available = Self.viewport.width - Self.style.dividerThickness
        let step = available * CGFloat(PaneResize.step)
        let left = Self.presses(.left, 12, on: "p1", from: start, edge: divider)
        let back = Self.presses(.right, 4, on: "p1", from: left.layout, edge: divider)
        let lastLeft = left.edges.compactMap { $0 }.last ?? divider(base)
        Self.check(towardLimit: Self.moves(from: divider(base), left.edges), back: Self.moves(from: lastLeft, back.edges), step: step)
        // And the other side: to the maximum and one press back.
        let right = Self.presses(.right, 12, on: "p1", from: start, edge: divider)
        let backLeft = Self.presses(.left, 2, on: "p1", from: right.layout, edge: divider)
        let lastRight = right.edges.compactMap { $0 }.last ?? divider(base)
        Self.check(towardLimit: Self.moves(from: divider(base), right.edges), back: Self.moves(from: lastRight, backLeft.edges), step: step)
    }

    /// p1 is the last column: Left moves its left edge, so c0 narrows to its minimum and c1 takes the width it gives.
    @Test func columnPressesStopAtTheColumnMinimumAndComeBackAWholeStep() {
        let start = ScreenLayout.columns([LayoutColumn(id: "c0", width: 0.5, root: .leaf("p0")),
                                          LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1"))])
        let width: (ScreenGeometry) -> CGFloat = { $0.columns["c1"]?.width ?? -1 }
        let base = ScreenGeometry.compute(start, viewport: Self.viewport, style: Self.style)
        let narrower = Self.presses(.left, 12, on: "p1", from: start, edge: width)
        let back = Self.presses(.right, 3, on: "p1", from: narrower.layout, edge: width)
        let step = (Self.viewport.width - Self.style.stripGap) * CGFloat(PaneResize.step)
        let last = narrower.edges.compactMap { $0 }.last ?? width(base)
        Self.check(towardLimit: Self.moves(from: width(base), narrower.edges), back: Self.moves(from: last, back.edges), step: step)
    }
}
