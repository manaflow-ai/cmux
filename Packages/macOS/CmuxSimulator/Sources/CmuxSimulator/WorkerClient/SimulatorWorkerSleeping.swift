import Foundation

protocol SimulatorWorkerSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousSimulatorWorkerSleeper: SimulatorWorkerSleeping {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
