/// The engine's timer source: one-shot sleeps, cancelled with their task.
/// Injected so tests drive timers deterministically (idle-wakeups.md:
/// nothing polls; an app timer is one sleep per firing).
public nonisolated protocol AppEngineClock: Sendable {
    func delay(for duration: Duration) async throws
}

/// The real clock.
public nonisolated struct ContinuousAppEngineClock: AppEngineClock {
    public init() {}

    public func delay(for duration: Duration) async throws {
        // wakeup-allow: one-shot app timer (cmux.timer.after/every), cancelled by clearTimer, unmount and stop
        try await ContinuousClock().sleep(for: duration)
    }
}
