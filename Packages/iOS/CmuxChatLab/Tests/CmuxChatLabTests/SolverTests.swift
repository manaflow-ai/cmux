import CoreGraphics
import Testing

@testable import CmuxChatLab

struct GrowingTextHeightSolverTests {
    @Test func clampsToMinimum() {
        let result = GrowingTextHeightSolver.solve(fittingHeight: 10, minHeight: 36, maxHeight: 140)
        #expect(result.height == 36)
        #expect(result.scrollEnabled == false)
    }

    @Test func growsWithinBand() {
        let result = GrowingTextHeightSolver.solve(fittingHeight: 80, minHeight: 36, maxHeight: 140)
        #expect(result.height == 80)
        #expect(result.scrollEnabled == false)
    }

    @Test func clampsAndScrollsAtCap() {
        let result = GrowingTextHeightSolver.solve(fittingHeight: 400, minHeight: 36, maxHeight: 140)
        #expect(result.height == 140)
        #expect(result.scrollEnabled == true)
    }

    @Test func growthIsMonotonic() {
        var previous: CGFloat = 0
        for fitting in stride(from: CGFloat(0), through: 200, by: 10) {
            let height = GrowingTextHeightSolver.solve(fittingHeight: fitting, minHeight: 36, maxHeight: 140).height
            #expect(height >= previous)
            previous = height
        }
    }
}

struct KeyboardSyncSolverTests {
    @Test func bottomOverlapNeverNegative() {
        #expect(KeyboardSyncSolver.bottomOverlap(listMaxY: 800, composerTopInList: 900) == 0)
    }

    @Test func bottomOverlapIsIntrusion() {
        #expect(KeyboardSyncSolver.bottomOverlap(listMaxY: 800, composerTopInList: 500) == 300)
    }

    @Test func pinnedWhenAtInvertedBottom() {
        #expect(KeyboardSyncSolver.isPinnedToBottom(contentOffsetY: -340, topInset: 340))
        #expect(KeyboardSyncSolver.isPinnedToBottom(contentOffsetY: -339.5, topInset: 340))
        #expect(!KeyboardSyncSolver.isPinnedToBottom(contentOffsetY: -100, topInset: 340))
    }
}
