import Foundation

/// Production HID pacing backed by Swift's cancellable continuous clock.
struct ContinuousSimulatorHIDSleeper: SimulatorHIDSleeping {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
