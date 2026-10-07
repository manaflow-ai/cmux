import NIOCore

/// Kernel TCP keepalive for an SSH transport. The OS probes an idle
/// connection, so a dead path closes the connection without any app timer
/// (zero idle wakeups in the process). Only the outermost hop has a TCP
/// socket; a connection tunneled through a jump host inherits the jump's.
public struct SSHKeepalive: Hashable, Sendable {
    /// Idle seconds before the first probe.
    public var idleSeconds: Int
    /// Seconds between unanswered probes.
    public var intervalSeconds: Int
    /// Unanswered probes before the connection is dropped.
    public var probeCount: Int

    public init(idleSeconds: Int = 30, intervalSeconds: Int = 10, probeCount: Int = 3) {
        self.idleSeconds = max(1, idleSeconds)
        self.intervalSeconds = max(1, intervalSeconds)
        self.probeCount = max(1, probeCount)
    }

    /// Seconds from the last traffic until a dead path is reported.
    public var detectionSeconds: Int { idleSeconds + intervalSeconds * probeCount }
}
