import Foundation

/// Uses the continuous system clock as the live automation scheduler.
public struct ContinuousSimulatorUIAutomationScheduler:
    SimulatorUIAutomationScheduling
{
    /// Creates the live system-clock implementation.
    public init() {}

    public func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    public func nextEvent(after duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
