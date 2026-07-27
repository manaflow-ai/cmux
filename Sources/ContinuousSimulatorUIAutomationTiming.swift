import Foundation

/// Uses the continuous system clock for live Simulator UI automation.
struct ContinuousSimulatorUIAutomationTiming: SimulatorUIAutomationTiming {
    func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
