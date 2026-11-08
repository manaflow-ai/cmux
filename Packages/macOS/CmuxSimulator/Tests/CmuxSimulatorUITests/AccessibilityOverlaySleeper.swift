@testable import CmuxSimulatorUI

actor AccessibilityOverlaySleeper: SimulatorProcessSleeper {
    private var startCount = 0
    private var cancellationCount = 0

    func sleep(for duration: Duration) async throws {
        _ = duration
        startCount += 1
        do {
            try await ContinuousClock().sleep(for: .seconds(3_600))
        } catch {
            cancellationCount += 1
            throw error
        }
    }

    func counts() -> (starts: Int, cancellations: Int) {
        (startCount, cancellationCount)
    }
}
