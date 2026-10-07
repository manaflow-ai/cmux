/// A way to reach a host (V1 WebRTC, V2 WebRTC over WireGuard, V3 direct,
/// the DO relay). Carrier lanes implement this and nothing above it.
public protocol LinkCarrier: Sendable {
    var kind: CarrierKind { get }
    /// The paths a successful connect can produce, best first. The selector
    /// waits for a pending carrier only if it could beat the current winner.
    var candidatePaths: [PathKind] { get }
    func connect(to peer: LinkPeer) async throws -> any LinkTransport
}
