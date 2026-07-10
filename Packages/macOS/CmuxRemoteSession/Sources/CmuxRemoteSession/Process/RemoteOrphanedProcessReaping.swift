/// Cleans up stale cmux-owned SSH transports before a remote connection starts.
public protocol RemoteOrphanedProcessReaping: Sendable {
    /// Finds and terminates orphaned transports matching one remote destination.
    ///
    /// - Parameters:
    ///   - destination: SSH destination used by the remote workspace.
    ///   - relayPort: Optional reverse-relay port used to narrow matches.
    ///   - persistentDaemonSlot: Optional daemon slot used to narrow matches.
    func reap(destination: String, relayPort: Int?, persistentDaemonSlot: String?) async
}
