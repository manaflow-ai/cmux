import Foundation
@testable import CmuxSimulator

actor CameraReplayDeadlineSleeper: SimulatorWorkerSleeping {
    private var replayCallCount = 0

    func sleep(for duration: Duration) async throws {
        guard duration == .milliseconds(1) else {
            try await ContinuousClock().sleep(for: .seconds(3_600))
            return
        }
        replayCallCount += 1
        if replayCallCount == 1 {
            try await ContinuousClock().sleep(for: .seconds(3_600))
        }
    }
}
