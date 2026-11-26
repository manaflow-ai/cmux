import Foundation
@testable import CmuxSimulatorWorker

actor FirstImmediateToolSleeper: SimulatorHIDSleeping {
    private var callCount = 0

    func sleep(for duration: Duration) async throws {
        callCount += 1
        if callCount > 1 {
            try await ContinuousClock().sleep(for: .seconds(3_600))
        }
    }
}
