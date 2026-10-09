public import CmuxLink
public import CmuxLinkWG
public import CmuxLinkWebRTC
public import Foundation

/// B3's `DatagramUnderlay` on a B2 datagram channel: one WebRTC peer
/// connection whose `wg` data channel (`ordered: false, maxRetransmits: 0`)
/// carries WireGuard datagrams (b3-webrtc-wg.md section 1).
public final class WebRTCUnderlay: DatagramUnderlay {
    public let channel: WebRTCDatagramChannel
    /// Mapped from the channel on demand; no buffer of its own (E1).
    public var events: AsyncStream<UnderlayEvent> {
        let channel = channel
        return AsyncStream(unfolding: {
            switch await channel.next() {
            case nil: nil
            case let .datagram(data)?: .datagram(data)
            case let .pathChanged(kind)?: .pathChanged(kind)
            case .closed(.local)?: .closed(.local)
            case .closed(.reset)?: .closed(.reset)
            case let .closed(.pathLost(detail))?: .closed(.pathLost(detail))
            }
        })
    }

    public init(channel: WebRTCDatagramChannel) {
        self.channel = channel
    }

    public var path: PathKind {
        get async { await channel.path }
    }

    public var maxDatagramBytes: Int { channel.maxDatagramBytes }

    public func send(_ datagram: Data) async throws {
        try await channel.send(datagram)
    }

    public func close() async {
        await channel.close()
    }
}
