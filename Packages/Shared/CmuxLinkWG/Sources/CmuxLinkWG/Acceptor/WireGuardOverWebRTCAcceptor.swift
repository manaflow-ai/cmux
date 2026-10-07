public import CmuxLink
import Foundation

/// V2 host: answers WireGuard initiations from authorized device keys on
/// every underlay the listener yields, and routes a new underlay whose first
/// datagram belongs to a live session to that session (roaming).
public final class WireGuardOverWebRTCAcceptor: LinkAcceptor {
    public let incoming: AsyncStream<any LinkTransport>

    private let state: AcceptorState
    private let underlays: any DatagramUnderlayListener

    public init(
        identity: WireGuardPrivateKey,
        hostID: String,
        underlays: any DatagramUnderlayListener,
        authorizer: any WireGuardAuthorizer,
        configuration: WireGuardLinkConfiguration = WireGuardLinkConfiguration(),
        clock: LinkClock = .continuous,
        source: WireGuardHandshakeSource = WireGuardHandshakeSource()
    ) {
        let (stream, sink) = AsyncStream.makeStream(of: (any LinkTransport).self, bufferingPolicy: .unbounded)
        incoming = stream
        self.underlays = underlays
        state = AcceptorState(
            identity: identity, hostID: hostID, authorizer: authorizer,
            configuration: configuration, clock: clock, source: source, sink: sink
        )
    }

    /// Starts reading the listener. Idempotent.
    public func start() async {
        await state.start(underlays.incoming)
    }

    /// Stops accepting and closes every live transport.
    public func stop() async {
        await state.stop()
    }

    /// Live (established or handshaking) transports.
    public var liveTransportCount: Int {
        get async { await state.liveCount }
    }
}
