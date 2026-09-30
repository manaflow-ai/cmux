/// Cancels a scheduled restore-spawn delay.
@MainActor
public protocol TerminalSurfaceRestoreSpawnDelayCancelling: AnyObject {
    /// Cancels the scheduled delayed operation if it has not fired.
    func cancel()
}
