import Foundation

struct ContinuousSimulatorWorkerSleeper: SimulatorWorkerSleeping {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
