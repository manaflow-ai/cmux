import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Inputs outside their documented ranges used to trap in a precondition.
@Suite struct OutOfRangeShellLimitTests {
    @Test func chunkPlanCorrectsNegativeTotalAndEmptyChunk() {
        let plan = MobileTaskAttachmentChunkPlan(totalByteCount: -5, chunkByteCount: 0)
        #expect(plan.totalByteCount == 0)
        #expect(plan.chunkByteCount == MobileTaskAttachmentChunkPlan.defaultChunkByteCount)
        #expect(plan.ranges == [0..<0])
        #expect(MobileTaskAttachmentChunkPlan(totalByteCount: 5, chunkByteCount: -1).ranges == [0..<5])
    }

    @Test func sendBufferZeroCapEmitsOneScalarPerBatch() {
        var buffer = MobileTerminalInputSendBuffer()
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-a")
        #expect(buffer.enqueue("ab", workspaceID: workspaceID, terminalID: terminalID) == .startDraining)
        #expect(buffer.nextBatch(maximumByteCount: 0)?.text == "a")
        #expect(buffer.nextBatch(maximumByteCount: 0)?.text == "b")
        // The split chunk ends with its empty final piece, which carries the settle.
        #expect(buffer.nextBatch(maximumByteCount: 0)?.text == "")
        #expect(buffer.nextBatch(maximumByteCount: 0) == nil)
    }
}
