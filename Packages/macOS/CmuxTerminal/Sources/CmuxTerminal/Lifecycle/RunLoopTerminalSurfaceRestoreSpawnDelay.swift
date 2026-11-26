import Foundation

/// Cancellation handle for a run-loop restore-spawn timer.
@MainActor
public final class RunLoopTerminalSurfaceRestoreSpawnDelay: TerminalSurfaceRestoreSpawnDelayCancelling {
    private let timer: Timer

    /// Creates a cancellation handle for a scheduled timer.
    ///
    /// - Parameter timer: The timer to invalidate if cancellation is requested.
    init(timer: Timer) {
        self.timer = timer
    }

    /// Cancels the delayed spawn if it has not fired yet.
    public func cancel() {
        timer.invalidate()
    }
}
