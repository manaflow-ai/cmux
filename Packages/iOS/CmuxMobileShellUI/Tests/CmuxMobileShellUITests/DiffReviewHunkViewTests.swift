import CmuxDiffModel
import Testing

@testable import CmuxMobileShellUI

@MainActor
@Suite struct DiffReviewHunkViewTests {
    @Test func oldLineAccessibilityRangeHandlesMaximumCount() {
        let view = makeView(
            oldStart: 1,
            oldCount: Int.max,
            newStart: 1,
            newCount: 1
        )

        _ = view.body
    }

    @Test func newLineAccessibilityRangeHandlesMaximumCount() {
        let view = makeView(
            oldStart: 1,
            oldCount: 1,
            newStart: 1,
            newCount: Int.max
        )

        _ = view.body
    }

    private func makeView(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int
    ) -> DiffReviewHunkView {
        DiffReviewHunkView(
            hunk: DiffHunk(
                id: 0,
                header: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@",
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                lines: []
            ),
            position: 1,
            total: 1,
            moveBackward: {},
            moveForward: {}
        )
    }
}
