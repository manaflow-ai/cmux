import Foundation

/// Production restore-spawn timer backed by the main run loop.
///
/// Restore pacing is deliberately time-cadenced: the external macOS cost we are
/// avoiding is simultaneous `/usr/bin/login` PAM and Launch Services work, not
/// an in-process readiness signal. A one-shot run-loop timer spreads those
/// native spawns without blocking Swift's cooperative executor.
@MainActor
public final class RunLoopTerminalSurfaceRestoreSpawnDelayer: TerminalSurfaceRestoreSpawnDelaying {
    /// Creates a main-run-loop delay primitive.
    public init() {}

    /// Schedules the configured restore-spawn cadence without blocking a thread.
    public func scheduleDelay(
        for duration: Duration,
        operation: @escaping @MainActor () -> Void
    ) -> any TerminalSurfaceRestoreSpawnDelayCancelling {
        let timer = Timer(
            timeInterval: duration.timeInterval,
            repeats: false
        ) { timer in
            timer.invalidate()
            Task { @MainActor in
                operation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return RunLoopTerminalSurfaceRestoreSpawnDelay(timer: timer)
    }
}
