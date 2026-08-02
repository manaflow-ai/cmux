import Foundation
@testable import CmuxSimulator

struct AccessibilityTimeoutSleeper: SimulatorWorkerSleeping {
    func sleep(for duration: Duration) async throws {
        if duration == .milliseconds(100) { return }
        try await ContinuousClock().sleep(for: .seconds(3_600))
    }
}
