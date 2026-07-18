import Testing
@testable import CmuxTerminalRenderCompositor

struct TerminalRenderMetalTraceLabelsTests {
    @Test
    func hostLabelsRemainStableForCrossProcessTraceEvidence() {
        #expect(
            TerminalRenderMetalTraceLabels.hostCommandBuffer
                == "cmux host compositor: one IOSurface blit"
        )
        #expect(
            TerminalRenderMetalTraceLabels.hostBlitEncoder
                == "cmux host compositor: no Ghostty rendering"
        )
    }
}
