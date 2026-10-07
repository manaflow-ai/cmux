import CmuxLink

/// A carrier under test. Carrier lanes implement this over their real
/// transport (for example two in-process WebRTC peers) and run
/// `LinkConformanceSuite` from their Swift Testing target. Fault hooks return
/// `false` when the carrier cannot inject that fault; the cases that need it
/// are then skipped, never passed.
public protocol ConformanceHarness: Sendable {
    var name: String { get }
    /// Fresh endpoints for one case.
    func makeEndpoints() async throws -> ConformanceEndpoints
    /// Kills every live transport under both ends.
    func dropTransports() async -> Bool
    /// Moves live transports to `kind` without dropping them.
    func changePath(to kind: PathKind) async -> Bool
    /// A network change: live transports die and reconnects land on `kind`.
    func roam(to kind: PathKind) async -> Bool
    /// Limits the transport's send rate (`nil` removes the limit).
    func throttle(bytesPerSecond: Int?) async -> Bool
    /// Called after each case.
    func tearDown() async
}

extension ConformanceHarness {
    public func dropTransports() async -> Bool { false }
    public func changePath(to kind: PathKind) async -> Bool { false }
    public func roam(to kind: PathKind) async -> Bool { false }
    public func throttle(bytesPerSecond: Int?) async -> Bool { false }
    public func tearDown() async {}
}
