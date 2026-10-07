import CmuxTerminalRenderCore
import Testing

@Suite struct TerminalFramePacingTests {
    @Test func promotionGesturesAskFor120() {
        let pacing = TerminalFramePacing(displayMaximum: 120)
        #expect(pacing.gestureRange == .init(minimum: 80, maximum: 120, preferred: 120))
        #expect(pacing.outputFrameCap == nil)
        #expect(pacing.allowsCursorBlink)
        #expect(abs(pacing.frameBudget - 1.0 / 120) < 1e-12)
    }

    @Test func sixtyHertzDisplaysStayAtTheirMaximum() {
        let pacing = TerminalFramePacing(displayMaximum: 60)
        #expect(pacing.gestureRange == .init(minimum: 60, maximum: 60, preferred: 60))
        #expect(abs(pacing.frameBudget - 1.0 / 60) < 1e-12)
    }

    @Test(arguments: [
        TerminalFramePacing(thermal: .serious),
        TerminalFramePacing(thermal: .critical),
        TerminalFramePacing(lowPowerMode: true),
    ])
    func constrainedCapsAt30(_ pacing: TerminalFramePacing) {
        #expect(pacing.isConstrained)
        #expect(pacing.outputFrameCap == 30)
        #expect(!pacing.allowsCursorBlink)
        #expect(pacing.gestureRange.maximum == 30)
    }

    @Test func fairIsNotConstrained() {
        #expect(!TerminalFramePacing(thermal: .fair).isConstrained)
    }
}
