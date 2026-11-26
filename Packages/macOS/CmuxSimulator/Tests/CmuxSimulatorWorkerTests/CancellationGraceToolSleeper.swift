import Foundation
@testable import CmuxSimulatorWorker

actor CancellationGraceToolSleeper: SimulatorHIDSleeping {
    private var sleepCount = 0
    private var firstSleepStarted = false
    private var firstSleepWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async throws {
        sleepCount += 1
        guard sleepCount == 1 else { return }
        firstSleepStarted = true
        let waiters = firstSleepWaiters
        firstSleepWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await ContinuousClock().sleep(for: .seconds(3_600))
    }

    func waitUntilFirstSleepStarts() async {
        if firstSleepStarted { return }
        await withCheckedContinuation { firstSleepWaiters.append($0) }
    }
}
