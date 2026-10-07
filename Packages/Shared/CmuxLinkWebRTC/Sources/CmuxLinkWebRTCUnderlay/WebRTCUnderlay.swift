public import CmuxLink
public import CmuxLinkWG
public import CmuxLinkWebRTC
public import Foundation

/// B3's `DatagramUnderlay` on a B2 datagram channel: one WebRTC peer
/// connection whose `wg` data channel (`ordered: false, maxRetransmits: 0`)
/// carries WireGuard datagrams (b3-webrtc-wg.md section 1).
public final class WebRTCUnderlay: DatagramUnderlay {
    public let channel: WebRTCDatagramChannel
    public let events: AsyncStream<UnderlayEvent>
    private let pump: Task<Void, Never>

    public init(channel: WebRTCDatagramChannel) {
        self.channel = channel
        let (events, sink) = AsyncStream.makeStream(of: UnderlayEvent.self, bufferingPolicy: .unbounded)
        self.events = events
        let source = channel.events
        pump = Task {
            for await event in source {
                switch event {
                case let .datagram(data): sink.yield(.datagram(data))
                case let .pathChanged(kind): sink.yield(.pathChanged(kind))
                case .closed(.local): sink.yield(.closed(.local))
                case .closed(.reset): sink.yield(.closed(.reset))
                case let .closed(.pathLost(detail)): sink.yield(.closed(.pathLost(detail)))
                }
            }
            sink.finish()
        }
    }

    deinit { pump.cancel() }

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
