/// Production delay primitive backed by Swift's continuous clock.
public struct ContinuousTerminalSurfaceRestoreSpawnDelayer: TerminalSurfaceRestoreSpawnDelaying {
    /// Creates a continuous-clock delay primitive.
    public init() {}

    /// Waits for the configured restore-spawn cadence.
    public func delay(for duration: Duration) async {
        do {
            // Intended restore pacing: spread login-shell spawns, not poll or wait for state.
            try await ContinuousClock().sleep(for: duration)
        } catch {
            return
        }
    }
}
