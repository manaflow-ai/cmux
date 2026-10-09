public import CmuxLink
public import CmuxLinkWG
public import CmuxLinkWebRTC

/// B3's `DatagramUnderlayDialer` over `WebRTCDatagramDialer`.
public struct WebRTCUnderlayDialer: DatagramUnderlayDialer {
    public let dialer: WebRTCDatagramDialer

    public init(dialer: WebRTCDatagramDialer) {
        self.dialer = dialer
    }

    public func open(to peer: LinkPeer) async throws -> any DatagramUnderlay {
        WebRTCUnderlay(channel: try await dialer.open(to: peer))
    }
}
