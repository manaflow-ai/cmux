import Foundation

struct ContinuousSimulatorWebInspectorSleeper: SimulatorWebInspectorSleeping {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
