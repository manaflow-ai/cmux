import CMUXMobileCore
import CmuxIrohTransport
import CmuxNextTransport
import Foundation

/// Opens legacy-shaped lanes over one admitted next-transport connection.
/// The mirror of `BridgeLaneAcceptor`: the dialing side of every bridged
/// stream writes the descriptor preamble, then owns the bytes.
public enum BridgeLaneDialer {
    /// One legacy application lane (terminal, artifact, simulator stream).
    public static func openLane(
        on connection: IrohPeerConnection,
        lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        let raw = try await connection.openRawStream(
            preamble: BridgeLaneDescriptor.preamble(for: lane))
        try? await raw.setSendPriority(priority)
        return CmxIrohBidirectionalStream(bridging: raw)
    }

    /// The connection's single control transport for the legacy RPC service.
    public static func openControlTransport(
        on connection: IrohPeerConnection
    ) async throws -> BridgeByteTransport {
        let raw = try await connection.openRawStream(
            preamble: BridgeLaneDescriptor.preamble(for: .control))
        return BridgeByteTransport(stream: raw)
    }

    /// Host side: one server-event send stream toward the peer.
    public static func openServerEventSendStream(
        on connection: IrohPeerConnection,
        priority: Int32
    ) async throws -> any CmxIrohSendStream {
        let raw = try await connection.openRawStream(
            preamble: BridgeLaneDescriptor.preamble(for: .serverEvents(cursor: nil)))
        try? await raw.setSendPriority(priority)
        return BridgeSendStream(stream: raw)
    }
}
