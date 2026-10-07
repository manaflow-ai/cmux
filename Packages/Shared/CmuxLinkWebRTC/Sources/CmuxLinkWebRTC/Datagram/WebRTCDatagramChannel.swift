public import CmuxLink
public import Foundation

/// One peer connection carrying opaque datagrams on a single `wg` data
/// channel (`ordered: false, maxRetransmits: 0`): the V2 underlay
/// (b3-webrtc-wg.md). No fingerprint binding; whatever rides it (WireGuard)
/// authenticates itself.
public final class WebRTCDatagramChannel: Sendable {
    /// One SCTP chunk after DTLS and SCTP headers on a 1280-byte path MTU.
    public static let maxDatagramBytes = 1200

    public let events: AsyncStream<WebRTCDatagramEvent>
    let connection: WebRTCConnection
    private let highWater: UInt64
    private let pump: Task<Void, Never>

    init(raw: AsyncStream<TransportEvent>, connection: WebRTCConnection) {
        self.connection = connection
        highWater = connection.context.configuration.highWaterBytes
        let (events, sink) = AsyncStream.makeStream(of: WebRTCDatagramEvent.self, bufferingPolicy: .unbounded)
        self.events = events
        pump = Task {
            for await event in raw {
                switch event {
                case let .frame(frame):
                    sink.yield(.datagram(frame.bytes))
                case let .pathChanged(path):
                    sink.yield(.pathChanged(path.kind))
                case let .closed(reason):
                    let kind = await connection.endKind
                    switch (kind, reason) {
                    case (.local, _): sink.yield(.closed(.local))
                    case (.reset, _), (.remote, _): sink.yield(.closed(.reset))
                    case let (_, .pathLost(detail)): sink.yield(.closed(.pathLost(detail)))
                    default: sink.yield(.closed(.pathLost("\(reason)")))
                    }
                case .rtt, .health, .mediaTrack:
                    break
                }
            }
            sink.finish()
        }
    }

    deinit { pump.cancel() }

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
