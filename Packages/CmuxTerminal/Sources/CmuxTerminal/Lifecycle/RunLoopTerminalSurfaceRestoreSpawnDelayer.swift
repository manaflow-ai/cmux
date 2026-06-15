import Foundation

/// Production restore-spawn timer backed by the main run loop.
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
