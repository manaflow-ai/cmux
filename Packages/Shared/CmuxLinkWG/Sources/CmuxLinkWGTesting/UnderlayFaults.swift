public import CmuxLink

/// Fault hooks over an underlay network, for `WireGuardConformanceHarness`
/// (the in-memory network, or B2's real WebRTC underlay).
public protocol UnderlayFaults: Sendable {
    /// Ends every live underlay as `.reset` on both ends (the peer is gone).
    func reset() async
    /// Moves live underlays to `kind` without dropping them.
    func changePath(to kind: PathKind) async
    /// Ends live underlays as `.pathLost`; new ones report `kind`.
    func roam(to kind: PathKind) async
    /// Limits the send rate; false when the network cannot.
    func throttle(bytesPerSecond: Int?) async -> Bool
}
