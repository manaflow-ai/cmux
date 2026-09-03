import CMUXMobileCore
import CmuxIrohTransport
import CmuxNextTransport
import Foundation

/// Opens legacy-shaped lanes over one admitted next-transport connection.
/// The mirror of `BridgeLaneAcceptor`: the dialing side of every bridged
/// stream writes the descriptor preamble, then owns the bytes.
public enum BridgeLaneDialer {
    /// One legacy application lane (terminal, artifact, simulator stream).
    #if compiler(>=6.2)
    @concurrent
    #endif
    public static func openLane(
        on connection: IrohPeerConnection,
        lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        switch lane {
        case .terminal, .artifact, .simulatorStream:
            break
        case .control, .serverEvents:
            throw CmxIrohClientSessionError.invalidOutgoingLane
        }
        let preamble = try BridgeLaneDescriptor.preamble(for: lane)
        let openStart = ContinuousClock.now
        do {
            let raw = try await connection.openRawStream(preamble: preamble)
            do {
                try await raw.setSendPriority(priority)
            } catch {
                await raw.resetSend(errorCode: 1)
                await raw.stopReceiving(errorCode: 1)
                throw error
            }
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
    #if compiler(>=6.2)
    @concurrent
    #endif
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
    #if compiler(>=6.2)
    @concurrent
    #endif
    public static func openServerEventSendStream(
        on connection: IrohPeerConnection,
        priority: Int32
    ) async throws -> any CmxIrohSendStream {
        let openStart = ContinuousClock.now
        do {
            let raw = try await connection.openRawStream(
                preamble: BridgeLaneDescriptor.preamble(for: .serverEvents(cursor: nil)))
            do {
                try await raw.setSendPriority(priority)
            } catch {
                await raw.resetSend(errorCode: 1)
                await raw.stopReceiving(errorCode: 1)
                throw error
            }
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
