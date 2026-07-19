/// Injected monotonic time and cancellable delay operations for the detector scheduler.
public struct AgentTerminalDetectionClock: Sendable {
    private let nowOperation: @Sendable () async -> Duration
    private let sleepOperation: @Sendable (Duration) async throws -> Void

    /// Creates a clock seam from monotonic operations.
    public init(
        now: @escaping @Sendable () async -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        nowOperation = now
        sleepOperation = sleep
    }

    /// Returns elapsed monotonic time from the clock's private origin.
    public func now() async -> Duration {
        await nowOperation()
    }

    /// Suspends for an intended debounce/deadline delay.
    public func sleep(for duration: Duration) async throws {
        try await sleepOperation(duration)
    }

    /// A production clock backed by ``ContinuousClock``.
    public static func continuous() -> AgentTerminalDetectionClock {
        let clock = ContinuousClock()
        let origin = clock.now
        return AgentTerminalDetectionClock(
            now: { origin.duration(to: clock.now) },
            sleep: { duration in try await clock.sleep(for: duration) }
        )
    }
}
