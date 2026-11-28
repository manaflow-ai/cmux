import Foundation
@testable import CmuxSimulator

struct ForegroundTimeoutSleeper: SimulatorWorkerSleeping {
    func sleep(for duration: Duration) async throws {
        if duration == .seconds(15) { return }
        try await ContinuousClock().sleep(for: .seconds(3_600))
    }
}
