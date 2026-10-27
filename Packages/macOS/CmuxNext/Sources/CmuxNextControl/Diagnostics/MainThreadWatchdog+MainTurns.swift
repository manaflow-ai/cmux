import CmuxNextCompat

/// Main-thread turns (run-loop wake to sleep) for a recorder such as the startup trace
/// (CmuxNextLaunch's StartupTrace). The heartbeat stamps each wake in `turnStartNanos`; at the sleep that
/// ends the turn, a turn of at least `mainTurnMinimumNanos` goes to `mainTurnSink`. With no sink the
/// minimum is `.max`, so a turn costs one relaxed load and no lock.
extension MainThreadWatchdog {
    /// Sends each main-thread turn of at least `minimumNanos` to `sink` on the main thread, with its start and
    /// end in `CLOCK_UPTIME_RAW` nanoseconds. The sink must return at once: no I/O and no wait. Nil removes it.
    public func setMainTurnSink(minimumNanos: UInt64, _ sink: (@Sendable (_ start: UInt64, _ end: UInt64) -> Void)?) {
        mainTurnSink.withLock { $0 = sink }
        mainTurnMinimumNanos.store(sink == nil ? .max : minimumNanos, ordering: .relaxed)
    }

    /// The heartbeat's call at the sleep that ends a turn, with the wake and sleep stamps it took: the turn
    /// counts in ``turnHistogram`` and `main.turn` (``MainThreadFieldMetrics``; no clock read). A start of 0 is a
    /// turn whose wake was never seen.
    // perf-hot: 1us frame-tick
    func mainTurnEnded(start: UInt64, end: UInt64) {
        guard start > 0, end > start else { return }
        turnHistogram.record(nanos: end - start)
        fieldMetrics.turnEnded(start: start, end: end)
        guard end - start >= mainTurnMinimumNanos.load(ordering: .relaxed),
              let sink = mainTurnSink.withLock({ $0 }) else { return }
        sink(start, end)
    }

    /// A decided quit is ending: records the open `hang.over250.per_hour` interval, so the stalls of a launch's
    /// last active seconds are not lost (``MainThreadFieldMetrics/recordOpenInterval()``). Main thread, once.
    @MainActor
    public func recordFieldMetricsAtQuit() {
        fieldMetrics.recordOpenInterval()
    }
}
