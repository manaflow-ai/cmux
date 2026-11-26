import Foundation
@testable import CmuxSimulator

actor ImmediateTerminationSleeper: SimulatorWorkerSleeping {
    private(set) var callCount = 0

    func sleep(for duration: Duration) async throws {
        callCount += 1
    }
}
