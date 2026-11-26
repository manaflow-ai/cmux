import Foundation
@testable import CmuxSimulator

struct ReplayDeadlineSleeper: SimulatorWorkerSleeping {
    func sleep(for duration: Duration) async throws {
        if duration == .milliseconds(1) { return }
        try await ContinuousClock().sleep(for: .seconds(3_600))
    }
}
