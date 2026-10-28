/// An endpoint's identity is where it reaches the daemon: its socket, pid, generation and bridge. Not what its
/// connections count into (``DaemonEndpoint/wireStats``), nor where they note their requests
/// (``DaemonEndpoint/requests``: the main connection puts its heartbeat's note on its local daemon's endpoint,
/// ``DaemonConnectionConfiguration/countsStability(of:)``, so a terminal view's own connection notes its keys too).
extension DaemonEndpoint {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.socketPath == rhs.socketPath && lhs.pid == rhs.pid && lhs.generation == rhs.generation && lhs.bridge == rhs.bridge
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(socketPath)
        hasher.combine(pid)
        hasher.combine(generation)
        hasher.combine(bridge)
    }
}
