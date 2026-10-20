@testable import CmuxSwiftRenderUI
import Testing

struct ReorderMathTests {
    // Three 30pt rows: tops at 0/30/60, midpoints at 15/45/75.
    private let heights: [CGFloat] = [30, 30, 30]

    @Test func noTranslationStaysAtSource() {
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 1, translation: 0) == 1)
    }

    @Test func dragDownSwapsWhenBottomEdgePassesNextMidpoint() {
        // Row 0's bottom edge starts at 30; row 1's midpoint is 45 and
        // row 2's is 75. Swaps at translation > 15 and > 45.
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 0, translation: 14) == 0)
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 0, translation: 16) == 1)
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 0, translation: 46) == 2)
    }

    @Test func dragUpSwapsWhenTopEdgePassesPreviousMidpoint() {
        // Row 2's top edge starts at 60; row 1's midpoint is 45 and row 0's
        // is 15. Swaps at translation < -15 and < -45.
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 2, translation: -14) == 2)
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 2, translation: -16) == 1)
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 2, translation: -46) == 0)
    }

    @Test func targetClampsToBounds() {
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 0, translation: 10_000) == 2)
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 2, translation: -10_000) == 0)
    }

    @Test func unevenHeightsUseMidpoints() {
        // Rows 10/100/10. Row 1's midpoint sits at 60; dragging row 0 down,
        // its bottom edge (10) must pass it (translation > 50).
        let uneven: [CGFloat] = [10, 100, 10]
        #expect(ReorderMath.targetIndex(heights: uneven, sourceIndex: 0, translation: 49) == 0)
        #expect(ReorderMath.targetIndex(heights: uneven, sourceIndex: 0, translation: 51) == 1)
    }

    @Test func rowsShiftTowardTheVacatedSlot() {
        // Dragging row 0 to slot 2: rows 1 and 2 shift up by the dragged height.
        #expect(ReorderMath.rowShift(index: 1, sourceIndex: 0, targetIndex: 2, draggedHeight: 30) == -30)
        #expect(ReorderMath.rowShift(index: 2, sourceIndex: 0, targetIndex: 2, draggedHeight: 30) == -30)
        // Dragging row 2 to slot 0: rows 0 and 1 shift down.
        #expect(ReorderMath.rowShift(index: 0, sourceIndex: 2, targetIndex: 0, draggedHeight: 30) == 30)
        #expect(ReorderMath.rowShift(index: 1, sourceIndex: 2, targetIndex: 0, draggedHeight: 30) == 30)
        // Rows outside the affected span do not move.
        #expect(ReorderMath.rowShift(index: 2, sourceIndex: 0, targetIndex: 1, draggedHeight: 30) == 0)
        #expect(ReorderMath.rowShift(index: 0, sourceIndex: 0, targetIndex: 1, draggedHeight: 30) == 0)
    }

    @Test func hysteresisSplitsTheSwapBoundary() {
        // Static boundary for source 0 -> 1 is t > 15 (bottom edge 30 vs
        // midpoint 45). With margin 6: forward fires past 21, backward past 9.
        func target(_ t: CGFloat, current: Int) -> Int {
            ReorderMath.targetIndex(heights: heights, sourceIndex: 0, translation: t, current: current, hysteresis: 6)
        }
        #expect(target(16, current: 0) == 0)   // inside the dead band: hold
        #expect(target(22, current: 0) == 1)   // clearly past: swap
        #expect(target(16, current: 1) == 1)   // jitter back inside band: hold
        #expect(target(14, current: 1) == 1)   // still inside band: hold
        #expect(target(8, current: 1) == 0)    // clearly retreated: swap back
        // A large pull-back in one event returns multiple slots.
        #expect(target(8, current: 2) == 0)
    }

    @Test func settleResidualPreservesVisualPosition() {
        // Drag row 0 (top 0) down by 70: visual y = 70. New order [1,2,0]:
        // row 0's new slot top = 60. Residual = 10.
        #expect(ReorderMath.settleResidual(heights: heights, sourceIndex: 0, targetIndex: 2, translation: 70) == 10)
        // Drag row 2 (top 60) up by -55: visual y = 5. New order [2,0,1]:
        // new slot top = 0. Residual = 5.
        #expect(ReorderMath.settleResidual(heights: heights, sourceIndex: 2, targetIndex: 0, translation: -55) == 5)
        // No move: residual equals the translation itself.
        #expect(ReorderMath.settleResidual(heights: heights, sourceIndex: 1, targetIndex: 1, translation: 12) == 12)
    }

    @Test func projectedIndentFollowsTheTargetSlot() {
        // Layout: [row(10), header(8, fixed), member(22), member(22), row(10)]
        let indents: [CGFloat] = [10, 8, 22, 22, 10]
        let fixed = [false, true, false, false, false]
        // Dragging row 0 down under the header: adopt the member indent.
        #expect(ReorderMath.projectedIndent(indents: indents, fixed: fixed, sourceIndex: 0, targetIndex: 2) == 22)
        // Further down, above a member: still the member indent.
        #expect(ReorderMath.projectedIndent(indents: indents, fixed: fixed, sourceIndex: 0, targetIndex: 3) == 22)
        // Past the group, above the ungrouped row: base indent.
        #expect(ReorderMath.projectedIndent(indents: indents, fixed: fixed, sourceIndex: 0, targetIndex: 4) == 10)
        // Dragging a member (index 2) up to the very top: first non-fixed row.
        #expect(ReorderMath.projectedIndent(indents: indents, fixed: fixed, sourceIndex: 2, targetIndex: 0) == 10)
        // Member dragged below the last ungrouped row: base indent.
        #expect(ReorderMath.projectedIndent(indents: indents, fixed: fixed, sourceIndex: 2, targetIndex: 4) == 10)
        // Member staying in place: neighbor above is the header -> member indent.
        #expect(ReorderMath.projectedIndent(indents: indents, fixed: fixed, sourceIndex: 2, targetIndex: 2) == 22)
    }

    @Test func boundaryCandidatesAndPointerChoice() {
        // [row(10), header(8, fixed), member(22), member(22), row(10)]
        let indents: [CGFloat] = [10, 8, 22, 22, 10]
        let fixed = [false, true, false, false, false]
        // Dragging member 2 to slot 3 (last in group): above says in-group
        // (22), below says outside (10) -> ambiguous boundary.
        let b = ReorderMath.boundaryIndents(indents: indents, fixed: fixed, sourceIndex: 2, targetIndex: 3)
        #expect(b.above == 22)
        #expect(b.below == 10)
        // Pointer far left picks "below" (outside); far right stays "above".
        #expect(ReorderMath.boundarySide(above: 22, below: 10, pointerX: 4, current: "above") == "below")
        #expect(ReorderMath.boundarySide(above: 22, below: 10, pointerX: 24, current: "above") == "above")
        // Hysteresis: near the midpoint (16), the current side holds.
        #expect(ReorderMath.boundarySide(above: 22, below: 10, pointerX: 15, current: "above") == "above")
        #expect(ReorderMath.boundarySide(above: 22, below: 10, pointerX: 17, current: "below") == "below")
        // Unambiguous slots always report "above".
        #expect(ReorderMath.boundarySide(above: 10, below: 10, pointerX: -50, current: "above") == "above")
    }

    @Test func reorderedMovesElement() {
        #expect(ReorderMath.reordered(["a", "b", "c"], from: 0, to: 2) == ["b", "c", "a"])
        #expect(ReorderMath.reordered(["a", "b", "c"], from: 2, to: 0) == ["c", "a", "b"])
        #expect(ReorderMath.reordered(["a", "b", "c"], from: 1, to: 1) == ["a", "b", "c"])
        #expect(ReorderMath.reordered(["a"], from: 0, to: 5) == ["a"])
    }
}

import CoreGraphics
