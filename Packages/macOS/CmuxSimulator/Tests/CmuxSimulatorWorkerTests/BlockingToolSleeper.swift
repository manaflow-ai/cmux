import Foundation
@testable import CmuxSimulatorWorker

struct BlockingToolSleeper: SimulatorHIDSleeping {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: .seconds(3_600))
    }
}
