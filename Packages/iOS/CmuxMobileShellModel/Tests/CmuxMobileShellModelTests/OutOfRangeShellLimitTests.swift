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
}
