import Foundation

/// Uses the continuous system clock as the live automation scheduler.
public struct ContinuousSimulatorUIAutomationScheduler:
    SimulatorUIAutomationScheduling
{
    private let clock: ContinuousClock
    private let origin: ContinuousClock.Instant

    /// Creates the live system-clock implementation.
    public init() {
        let clock = ContinuousClock()
        self.clock = clock
        origin = clock.now
    }

    /// Returns elapsed monotonic milliseconds since this scheduler was created.
    public func monotonicNowMilliseconds() -> Int64 {
        let components = origin.duration(to: clock.now).components
        return components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
    }

    /// Returns the current Unix epoch time in milliseconds.
    public func wallTimeNowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    /// Sleeps on the monotonic clock until the next sampling event.
    public func nextEvent(after duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
