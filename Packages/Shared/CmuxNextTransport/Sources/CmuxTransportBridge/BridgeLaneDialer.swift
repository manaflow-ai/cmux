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
        let preamble = BridgeLaneDescriptor.preamble(for: lane)
        let openStart = ContinuousClock.now
        do {
            let raw = try await connection.openRawStream(preamble: preamble)
            try? await raw.setSendPriority(priority)
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.notice(
                    """
                    dialer opened app lane conn=\(BridgeDebugLog.id(connection), privacy: .public) \
                    preamble=\(preamble, privacy: .public) \
                    priority=\(priority, privacy: .public) \
                    elapsedMs=\(BridgeDebugLog.ms(since: openStart), privacy: .public)
                    """)
            }
            return CmxIrohBidirectionalStream(bridging: raw)
        } catch {
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.error(
                    """
                    dialer app lane open FAILED conn=\(BridgeDebugLog.id(connection), privacy: .public) \
                    preamble=\(preamble, privacy: .public) \
                    priority=\(priority, privacy: .public) \
                    error=\(String(describing: error), privacy: .public) \
                    elapsedMs=\(BridgeDebugLog.ms(since: openStart), privacy: .public)
                    """)
            }
            throw error
        }
    }

    /// The connection's single control transport for the legacy RPC service.
    public static func openControlTransport(
        on connection: IrohPeerConnection
    ) async throws -> BridgeByteTransport {
        let openStart = ContinuousClock.now
        do {
            let raw = try await connection.openRawStream(
                preamble: BridgeLaneDescriptor.preamble(for: .control))
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.notice(
                    """
                    dialer opened control transport \
                    conn=\(BridgeDebugLog.id(connection), privacy: .public) \
                    elapsedMs=\(BridgeDebugLog.ms(since: openStart), privacy: .public)
                    """)
            }
            return BridgeByteTransport(stream: raw)
        } catch {
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.error(
                    """
                    dialer control transport open FAILED \
                    conn=\(BridgeDebugLog.id(connection), privacy: .public) \
                    error=\(String(describing: error), privacy: .public) \
                    elapsedMs=\(BridgeDebugLog.ms(since: openStart), privacy: .public)
                    """)
            }
            throw error
        }
    }

    /// Host side: one server-event send stream toward the peer.
    public static func openServerEventSendStream(
        on connection: IrohPeerConnection,
        priority: Int32
    ) async throws -> any CmxIrohSendStream {
        let openStart = ContinuousClock.now
        do {
            let raw = try await connection.openRawStream(
                preamble: BridgeLaneDescriptor.preamble(for: .serverEvents(cursor: nil)))
            try? await raw.setSendPriority(priority)
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.notice(
                    """
                    dialer opened server-event send stream \
                    conn=\(BridgeDebugLog.id(connection), privacy: .public) \
                    priority=\(priority, privacy: .public) \
                    elapsedMs=\(BridgeDebugLog.ms(since: openStart), privacy: .public)
                    """)
            }
            return BridgeSendStream(stream: raw)
        } catch {
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.error(
                    """
                    dialer server-event send stream open FAILED \
                    conn=\(BridgeDebugLog.id(connection), privacy: .public) \
                    priority=\(priority, privacy: .public) \
                    error=\(String(describing: error), privacy: .public) \
                    elapsedMs=\(BridgeDebugLog.ms(since: openStart), privacy: .public)
                    """)
            }
            throw error
        }
    }
}
