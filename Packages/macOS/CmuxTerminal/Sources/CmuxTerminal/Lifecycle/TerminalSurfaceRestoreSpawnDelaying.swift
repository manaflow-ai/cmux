/// Timer primitive used by ``TerminalSurfaceRestoreSpawnScheduler``.
@MainActor
public protocol TerminalSurfaceRestoreSpawnDelaying: AnyObject {
    /// Schedules work after the configured restore-spawn cadence.
    ///
    /// - Parameters:
    ///   - duration: The intended spacing before the next restored terminal spawn.
    ///   - operation: The main-actor operation to run after the spacing interval.
    /// - Returns: A cancellation handle for the scheduled operation.
    func scheduleDelay(
        for duration: Duration,
        operation: @escaping @MainActor () -> Void
    ) -> any TerminalSurfaceRestoreSpawnDelayCancelling
}
