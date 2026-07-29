import Testing
@testable import CmuxSimulatorUI

@MainActor
@Suite("Simulator frame source failure")
struct SimulatorFrameSourceFailureTests {
    @Test("Pipeline reports a producer failure exactly once")
    func reportsProducerFailureOnce() {
        var failureCount = 0
        let pipeline = SimulatorFramePresentationPipeline(
            source: FailedSimulatorFrameSurfaceSource(),
            presentationDidComplete: {},
            sourceFailureDidOccur: {
                failureCount += 1
            }
        )
        defer { pipeline.invalidate() }

        #expect(pipeline.displayTick() == nil)
        #expect(failureCount == 1)
        #expect(pipeline.displayTick() == nil)
        #expect(failureCount == 1)
    }
}
