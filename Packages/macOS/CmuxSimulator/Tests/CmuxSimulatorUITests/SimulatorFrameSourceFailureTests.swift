import Foundation
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

    @Test("Controller stops fallback presentation after producer failure")
    func controllerStopsFallbackTimerAfterFailure() {
        var failureCount = 0
        let controller = SimulatorFramePresentationController(
            source: FailedSimulatorFrameSurfaceSource(),
            presentationDidComplete: { _ in },
            sourceFailureDidOccur: {
                failureCount += 1
            }
        )
        defer { controller.invalidate() }

        controller.startPresenting(maximumFramesPerSecond: 120)
        controller.presentLatestFrame()

        #expect(failureCount == 1)
        #expect(!hasFallbackPresentationTimer(controller))
    }

    @Test("Releasing a controller releases its active fallback timer")
    func releasingControllerReleasesFallbackTimer() {
        weak var retainedTimer: AnyObject?
        autoreleasepool {
            var controller: SimulatorFramePresentationController? =
                SimulatorFramePresentationController(
                    source: EmptySimulatorFrameSurfaceSource(),
                    presentationDidComplete: { _ in },
                    sourceFailureDidOccur: {}
                )
            controller?.startPresenting(maximumFramesPerSecond: 120)
            retainedTimer = fallbackPresentationTimer(controller)

            #expect(retainedTimer != nil)
            controller = nil
        }

        #expect(retainedTimer == nil)
    }

    private func hasFallbackPresentationTimer(
        _ controller: SimulatorFramePresentationController
    ) -> Bool {
        let timer = Mirror(reflecting: controller).children.first {
            $0.label == "presentationTimer"
        }
        guard let timer else { return false }
        return !Mirror(reflecting: timer.value).children.isEmpty
    }

    private func fallbackPresentationTimer(
        _ controller: SimulatorFramePresentationController?
    ) -> AnyObject? {
        guard let controller,
              let timer = Mirror(reflecting: controller).children.first(where: {
                  $0.label == "presentationTimer"
              }),
              let value = Mirror(reflecting: timer.value).children.first?.value
        else {
            return nil
        }
        return value as AnyObject
    }
}
