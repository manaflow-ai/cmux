/// Cleans up stale cmux-owned SSH transports before a remote connection starts.
public protocol RemoteOrphanedProcessReaping: Sendable {
    /// Finds and terminates orphaned transports matching one remote destination.
    ///
    /// - Parameters:
    ///   - destination: SSH destination used by the remote workspace.
    ///   - relayPort: Exact reverse-relay port proving transport ownership.
    ///   - persistentDaemonSlot: Exact persistent-daemon slot proving ownership.
    /// - Note: Cleanup is skipped when neither ownership key is available.
    func reap(destination: String, relayPort: Int?, persistentDaemonSlot: String?) async
}
