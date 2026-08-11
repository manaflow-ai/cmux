/// Supplies deterministic time and sleeps for ``AgentSyncEngine``.
public protocol SyncClock: Sendable {
    /// Returns monotonic milliseconds used for retry and malformed-frame windows.
    /// - Returns: Monotonic milliseconds.
    func nowMilliseconds() async -> Int64

    /// Sleeps for the requested duration.
    /// - Parameter milliseconds: Duration in milliseconds.
    func sleep(milliseconds: Int) async
}
