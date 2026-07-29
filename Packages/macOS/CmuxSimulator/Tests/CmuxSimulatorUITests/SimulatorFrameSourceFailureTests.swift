import Testing
@testable import CmuxSimulatorUI

@MainActor
@Suite("Simulator frame source failure")
struct SimulatorFrameSourceFailureTests {
    @Test("Failure sentinel is distinct from frame publications")
    func recognizesFailureSentinel() {
        #expect(
            SimulatorFramePublicationWord(rawValue: Int64.min)
                .reportsSourceFailure
        )
        #expect(
            !SimulatorFramePublicationWord(rawValue: 0)
                .reportsSourceFailure
        )
    }

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
