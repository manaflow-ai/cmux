@testable import CmuxSwiftRenderUI
import Testing

struct ReorderMathTests {
    // Three 30pt rows: tops at 0/30/60, midpoints at 15/45/75.
    private let heights: [CGFloat] = [30, 30, 30]

    @Test func noTranslationStaysAtSource() {
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 1, translation: 0) == 1)
    }

    @Test func dragDownCrossesNextRowCenter() {
        // Row 0's center starts at 15; row 1's center is 45. The reorder
        // happens when the dragged center passes it (translation > 30).
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 0, translation: 16) == 0)
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 0, translation: 31) == 1)
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 0, translation: 61) == 2)
    }

    @Test func dragUpCrossesPreviousRowCenter() {
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 2, translation: -16) == 2)
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 2, translation: -31) == 1)
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 2, translation: -61) == 0)
    }

    @Test func targetClampsToBounds() {
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 0, translation: 10_000) == 2)
        #expect(ReorderMath.targetIndex(heights: heights, sourceIndex: 2, translation: -10_000) == 0)
    }

    @Test func unevenHeightsUseMidpoints() {
        // Rows 10/100/10. Row 1's center sits at 60; dragging row 0 (center 5)
        // down must cross it (translation > 55) before taking its slot.
        let uneven: [CGFloat] = [10, 100, 10]
        #expect(ReorderMath.targetIndex(heights: uneven, sourceIndex: 0, translation: 40) == 0)
        #expect(ReorderMath.targetIndex(heights: uneven, sourceIndex: 0, translation: 56) == 1)
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

    @Test func reorderedMovesElement() {
        #expect(ReorderMath.reordered(["a", "b", "c"], from: 0, to: 2) == ["b", "c", "a"])
        #expect(ReorderMath.reordered(["a", "b", "c"], from: 2, to: 0) == ["c", "a", "b"])
        #expect(ReorderMath.reordered(["a", "b", "c"], from: 1, to: 1) == ["a", "b", "c"])
        #expect(ReorderMath.reordered(["a"], from: 0, to: 5) == ["a"])
    }
}

import CoreGraphics
