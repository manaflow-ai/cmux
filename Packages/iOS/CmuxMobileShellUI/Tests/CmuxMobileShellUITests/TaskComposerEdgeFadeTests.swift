import Testing

@testable import CmuxMobileShellUI

@Suite("Task composer horizontal edge fade")
struct TaskComposerEdgeFadeTests {
    @Test("edge stays opaque at rest")
    func opaqueAtRest() {
        #expect(TaskComposerEdgeFadeScrollView.edgeAlpha(distance: 0) == 1)
        #expect(TaskComposerEdgeFadeScrollView.edgeAlpha(distance: -4) == 1)
    }

    @Test("fade ramps linearly as content approaches a control edge")
    func incrementalRamp() {
        #expect(abs(TaskComposerEdgeFadeScrollView.edgeAlpha(distance: 6) - 0.75) < 0.0001)
        #expect(abs(TaskComposerEdgeFadeScrollView.edgeAlpha(distance: 12) - 0.5) < 0.0001)
    }

    @Test("fade saturates after one band")
    func saturates() {
        #expect(TaskComposerEdgeFadeScrollView.edgeAlpha(distance: 24) == 0)
        #expect(TaskComposerEdgeFadeScrollView.edgeAlpha(distance: 500) == 0)
    }
}
