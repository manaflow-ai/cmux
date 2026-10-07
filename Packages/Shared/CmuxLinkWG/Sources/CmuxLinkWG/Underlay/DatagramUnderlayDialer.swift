public import CmuxLink

/// Opens an underlay to a host: B2 signals an offer through `HostDO`, runs
/// ICE with the minted TURN servers and opens the `wg` data channel.
public protocol DatagramUnderlayDialer: Sendable {
    func open(to peer: LinkPeer) async throws -> any DatagramUnderlay
}
