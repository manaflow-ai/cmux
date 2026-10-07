public import CmuxLink
public import Foundation

/// One peer connection carrying opaque datagrams on a single `wg` data
/// channel (`ordered: false, maxRetransmits: 0`): the V2 underlay
/// (b3-webrtc-wg.md). No fingerprint binding; whatever rides it (WireGuard)
/// authenticates itself.
public final class WebRTCDatagramChannel: Sendable {
    /// One SCTP chunk after DTLS and SCTP headers on a 1280-byte path MTU.
    public static let maxDatagramBytes = 1200

    /// Pulled from the peer's bounded inbox on demand, with no buffer of
    /// its own: datagrams past the inbox budget drop on arrival (counted in
    /// `droppedDatagrams`), closed and path events are never dropped (E1).
    public var events: AsyncStream<WebRTCDatagramEvent> {
        AsyncStream(unfolding: { [self] in await next() })
    }
    let connection: WebRTCConnection
    private let inbox: TransportInbox
    private let highWater: UInt64

    init(inbox: TransportInbox, connection: WebRTCConnection) {
        self.inbox = inbox
        self.connection = connection
        highWater = connection.context.configuration.highWaterBytes
    }

    /// Datagrams dropped because the consumer fell a full budget behind.
    public var droppedDatagrams: Int { inbox.stats.droppedFrames }

    /// The next event (one consumer); nil once the channel ended.
    public func next() async -> WebRTCDatagramEvent? {
        while let event = await inbox.next() {
            switch event {
            case let .frame(frame):
                return .datagram(frame.bytes)
            case let .pathChanged(path):
                return .pathChanged(path.kind)
            case let .closed(reason):
                let kind = await connection.endKind
                switch (kind, reason) {
                case (.local, _): return .closed(.local)
                case (.reset, _), (.remote, _): return .closed(.reset)
                case let (_, .pathLost(detail)): return .closed(.pathLost(detail))
                default: return .closed(.pathLost("\(reason)"))
                }
            case .rtt, .health, .mediaTrack:
                continue
            }
        }
        return nil
    }

    public var maxDatagramBytes: Int { Self.maxDatagramBytes }

    /// `.p2p` or `.turn`, from the selected candidate pair.
    public var path: PathKind {
        get async { await connection.path.kind }
    }

    /// Sends one datagram; suspends while the channel buffer is full.
    public func send(_ datagram: Data) async throws {
        guard datagram.count <= Self.maxDatagramBytes else { throw WebRTCTransportError.frameTooLarge(datagram.count) }
        try await connection.pacer.pace(datagram.count)
        do {
            try await connection.peer.sendDatagram(datagram, highWater: highWater)
        } catch {
            throw WebRTCTransportError.closed
        }
    }

    /// Ends the peer connection and tells the peer (`bye`, so it sees `reset`).
    public func close() async {
        await connection.close()
    }

    public func restartICE() async {
        await connection.restartICE()
    }
}
