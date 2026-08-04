import Foundation
@testable import CmuxSimulatorWorker

actor AccessibilityWatchdogSleeper: SimulatorHIDSleeping {
    private var deadlineContinuation: CheckedContinuation<Void, Never>?

    var deadlineIsArmed: Bool {
        deadlineContinuation != nil
    }

    func sleep(for duration: Duration) async throws {
        guard duration == .seconds(30) else { return }
        await withCheckedContinuation { deadlineContinuation = $0 }
    }

    func fireDeadline() {
        deadlineContinuation?.resume()
        deadlineContinuation = nil
    }
}
