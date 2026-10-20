import Foundation

struct ContinuousSimulatorSubprocessSleeper: SimulatorSubprocessSleeping {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
