import Foundation
@testable import CmuxSimulatorWorker

actor FastEscalationSubprocessSleeper: SimulatorSubprocessSleeping {
    private(set) var callCount = 0

    func sleep(for duration: Duration) async throws {
        callCount += 1
        if duration == .milliseconds(50) {
            try await ContinuousClock().sleep(for: duration)
        }
    }
}
