/// What an interactive surface shows about the link's path: its kind, the
/// carrier and the smoothed round-trip time when known.
public struct PathBadge: Sendable, Hashable {
    public var path: LinkPath
    public var rtt: Duration?

    public init(path: LinkPath, rtt: Duration? = nil) {
        self.path = path
        self.rtt = rtt
    }

    /// transport.md 1.1: shown on every relayed path and above 50 ms RTT.
    public var shouldShow: Bool {
        if path.kind.isRelayed { return true }
        guard let rtt else { return false }
        return rtt > .milliseconds(50)
    }

    public var rttMilliseconds: Double? {
        guard let rtt else { return nil }
        let parts = rtt.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
