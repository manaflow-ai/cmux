/// Schedules cancellation-aware sampling without coupling automation to a clock.
public protocol SimulatorUIAutomationScheduling: Sendable {
    /// Returns monotonic elapsed time in milliseconds for deadlines.
    func monotonicNowMilliseconds() -> Int64
    /// Returns Unix epoch time in milliseconds for serialized snapshots.
    func wallTimeNowMilliseconds() -> Int64
    /// Produces the next scheduled event or throws when cancellation wins.
    func nextEvent(after duration: Duration) async throws
}
