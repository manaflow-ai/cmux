import Foundation

/// Production sync clock backed by Foundation time and `Task.sleep`.
public struct RealSyncClock: SyncClock {
    /// Creates a production sync clock.
    public init() {}

    /// Returns monotonic milliseconds based on continuous uptime.
    /// - Returns: Monotonic milliseconds.
    public func nowMilliseconds() async -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1_000)
    }

    /// Sleeps for the requested duration.
    /// - Parameter milliseconds: Duration in milliseconds.
    public func sleep(milliseconds: Int) async {
        let nanoseconds = UInt64(max(0, milliseconds)) * 1_000_000
        // Intended retry/debounce delay behind the injected clock seam.
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
