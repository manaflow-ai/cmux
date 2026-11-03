/// The packet tunnel's path rule: which network path updates mean the engine must rebind.
///
/// `NWPathMonitor` calls its handler once with the current path when it starts, then on every
/// update. The first path is the one the engine started on, so it is not a change; a later path
/// that equals the last one (a repeated update) is not a change either. Only a real change
/// (Wi-Fi to Ethernet, a wake on another network) passes, and then the engine rebinds its UDP
/// socket and handshakes again.
///
/// Generic over the path so the rule is testable without a tunnel; the extension uses `NWPath`.
/// Not thread-safe: the owner calls it from one serial queue (the monitor's).
public struct CloudTunnelPathChangeGate<Path: Equatable> {
    private var last: Path?

    public init() {}

    /// Records `path` and returns whether it is a real change from the path before it.
    public mutating func admit(_ path: Path) -> Bool {
        defer { last = path }
        guard let last else { return false }
        return last != path
    }
}
