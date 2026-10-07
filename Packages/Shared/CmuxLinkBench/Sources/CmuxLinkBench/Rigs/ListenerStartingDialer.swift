import CmuxLink
import CmuxLinkWG
import CmuxLinkWebRTCUnderlay

/// A WebRTC underlay dialer that starts the matching listener first.
struct ListenerStartingDialer: DatagramUnderlayDialer {
    let inner: WebRTCUnderlayDialer
    let listener: ListenerStarter

    func open(to peer: LinkPeer) async throws -> any DatagramUnderlay {
        await listener.ensure()
        return try await inner.open(to: peer)
    }
}
