import Testing

@testable import CmuxMobileShellUI

@Suite("Horizontal edge fade")
struct HorizontalEdgeFadeTests {
    @Test("edge stays opaque at rest")
    func opaqueAtRest() {
        #expect(HorizontalEdgeFadeScrollView.edgeAlpha(distance: 0) == 1)
        #expect(HorizontalEdgeFadeScrollView.edgeAlpha(distance: -4) == 1)
    }

    @Test("fade ramps linearly as content approaches a control edge")
    func incrementalRamp() {
        #expect(abs(HorizontalEdgeFadeScrollView.edgeAlpha(distance: 6) - 0.75) < 0.0001)
        #expect(abs(HorizontalEdgeFadeScrollView.edgeAlpha(distance: 12) - 0.5) < 0.0001)
    }

    @Test("fade saturates after one band")
    func saturates() {
        #expect(HorizontalEdgeFadeScrollView.edgeAlpha(distance: 24) == 0)
        #expect(HorizontalEdgeFadeScrollView.edgeAlpha(distance: 500) == 0)
    }
}
