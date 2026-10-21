/// Tells whether the network can carry a pack download, and waits for one
/// that can.
///
/// ``PathMonitorChromiumRuntimeNetwork`` follows `NWPathMonitor`; tests pass
/// a fake that is always online or that they release.
public protocol ChromiumRuntimeNetwork: Sendable {
    /// True when a usable path exists now.
    ///
    /// - Parameter allowsExpensive: False for a background prefetch: Low Data
    ///   Mode (constrained) and expensive paths (a phone hotspot) do not count.
    func isUsable(allowsExpensive: Bool) async -> Bool

    /// Returns when a usable path exists (at once when one does).
    ///
    /// - Parameter allowsExpensive: As for ``isUsable(allowsExpensive:)``.
    /// - Throws: `CancellationError` when the waiting task is cancelled.
    func waitUntilUsable(allowsExpensive: Bool) async throws
}
