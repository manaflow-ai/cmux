/// Delay primitive used by ``TerminalSurfaceRestoreSpawnScheduler``.
public protocol TerminalSurfaceRestoreSpawnDelaying: Sendable {
    /// Waits before the next restored terminal spawn is allowed to run.
    func delay(for duration: Duration) async
}
