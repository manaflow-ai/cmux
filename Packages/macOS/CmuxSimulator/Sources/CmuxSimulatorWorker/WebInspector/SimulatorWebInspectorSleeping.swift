import Foundation

protocol SimulatorWebInspectorSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousSimulatorWebInspectorSleeper: SimulatorWebInspectorSleeping {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
