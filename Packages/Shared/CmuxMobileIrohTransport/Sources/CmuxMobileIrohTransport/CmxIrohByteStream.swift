public import CMUXMobileCore
public import Foundation
import Dispatch
internal import CmuxIrohFFI

/// One open iroh QUIC bidirectional stream, with byte receive/send/close. Used
/// by both ends: the phone's ``CmxIrohByteTransport`` holds the stream it dialed,
/// and the Mac's ``CmxIrohByteListener`` hands one back per accepted connection
/// (the server-side `MobileHostByteConnection` mirror from the design).
///
/// Owns only the connection handle, never the endpoint: the endpoint's lifetime
/// belongs to whoever bound it (the transport or the listener). Blocking FFI
/// calls run on a concurrent queue so an indefinite `receive()` never stalls a
/// concurrent `close()`, which the registry-backed handle forces to return.
public actor CmxIrohByteStream {
    /// Upper bound on one `send`. Unlike `receive` (which legitimately waits
    /// indefinitely for the peer's next frame and is unblocked by `close`), a
    /// write only stalls when the peer stopped draining QUIC flow control — a
    /// peer gone for this long is effectively dead. Without a bound, the Mac
    /// host's `sendResponse` awaits forever, its response task pins the
    /// connection registered with idle timeout suppressed, and enough stalled
    /// peers wedge every mobile-host slot. On timeout the FFI returns an error,
    /// the send throws, and both ends' callers close the connection.
    private static let sendTimeoutMs: UInt64 = 30_000

    private var connection: OpaquePointer?
    private let maximumReceiveLength: Int
    private var didClose = false

    private nonisolated let blockingQueue = DispatchQueue(
        label: "dev.cmux.iroh.stream",
        attributes: .concurrent
    )

    init(connection: OpaquePointer, maximumReceiveLength: Int) {
        self.connection = connection
        self.maximumReceiveLength = maximumReceiveLength
    }

    public func connectionPathKind() -> String {
        guard let connection, !didClose else { return "unknown" }
        let outcome = CmxIrohByteTransport.withErrorBuffer { kindPtr, errBuf, cap in
            cmux_iroh_connection_type(connection, kindPtr, errBuf, cap)
        }
        guard outcome.errorKind == 0 else { return "unknown" }
        return CmxIrohByteTransport.pathKindName(outcome.result)
    }

    public func connectionDiagnostics(relayHint: String? = nil) async -> CmxConnectionDiagnostics? {
        guard let connection, !didClose else { return nil }
        let connectionBox = CmxIrohUnsafeBox(connection)
        let relayHint = relayHint?.isEmpty == false ? relayHint : nil

        return await runBlocking { () -> CmxConnectionDiagnostics? in
            let path = CmxIrohByteTransport.withErrorBuffer { kindPtr, errBuf, cap in
                cmux_iroh_connection_type(connectionBox.value, kindPtr, errBuf, cap)
            }
            guard path.errorKind == 0 else { return nil }

            let rtt = CmxIrohByteTransport.withErrorBuffer { kindPtr, errBuf, cap in
                cmux_iroh_connection_rtt_ms(connectionBox.value, kindPtr, errBuf, cap)
            }
            let rttMs = rtt.errorKind == 0 && rtt.result >= 0 ? rtt.result : nil

            var sent = UInt64(0)
            var received = UInt64(0)
            let stats = CmxIrohByteTransport.withErrorBuffer { kindPtr, errBuf, cap in
                cmux_iroh_connection_stats_bytes(
                    connectionBox.value,
                    &sent,
                    &received,
                    kindPtr,
                    errBuf,
                    cap
                )
            }
            let bytesSent = stats.result == 0 ? sent : nil
            let bytesReceived = stats.result == 0 ? received : nil

            let remoteID = CmxIrohByteTransport.takeString(
                cmux_iroh_connection_remote_id(connectionBox.value)
            )
            let selectedRelayURL = CmxIrohByteTransport.takeString(
                cmux_iroh_connection_relay_url(connectionBox.value)
            )
            let relayLabel = CmxIrohByteTransport.relayLabel(for: selectedRelayURL)
                ?? CmxIrohByteTransport.relayLabel(for: relayHint)

            return CmxConnectionDiagnostics(
                transportKind: .iroh,
                pathKind: CmxIrohByteTransport.diagnosticsPathKind(path.result),
                rttMs: rttMs,
                bytesSent: bytesSent,
                bytesReceived: bytesReceived,
                relayLabel: relayLabel,
                remoteEndpointId: remoteID?.isEmpty == false ? remoteID : nil
            )
        }
    }

    /// Reads the next chunk, or nil at a clean end of stream.
    public func receive() async throws -> Data? {
        if didClose { return nil }
        guard let connection else {
            throw CmxIrohByteTransportError.notConnected
        }
        let connectionBox = CmxIrohUnsafeBox(connection)
        let capacity = maximumReceiveLength

        let outcome = await runBlocking { () -> CmxIrohReceiveOutcome in
            var buffer = [UInt8](repeating: 0, count: capacity)
            let call = CmxIrohByteTransport.withErrorBuffer { kindPtr, errBuf, cap in
                buffer.withUnsafeMutableBufferPointer { bufferPointer in
                    Int(cmux_iroh_connection_recv(
                        connectionBox.value,
                        bufferPointer.baseAddress,
                        bufferPointer.count,
                        0,
                        kindPtr,
                        errBuf,
                        cap
                    ))
                }
            }
            return CmxIrohReceiveOutcome(count: call.result, message: call.message, buffer: buffer)
        }

        if outcome.count > 0 {
            return Data(outcome.buffer.prefix(outcome.count))
        }
        if outcome.count == 0 {
            return nil
        }
        if didClose {
            return nil
        }
        throw CmxIrohByteTransportError.receiveFailed(outcome.message)
    }

    /// Writes all of `data` (a no-op for empty data).
    public func send(_ data: Data) async throws {
        if didClose { throw CmxIrohByteTransportError.alreadyClosed }
        guard let connection else {
            throw CmxIrohByteTransportError.notConnected
        }
        if data.isEmpty { return }
        let connectionBox = CmxIrohUnsafeBox(connection)
        let bytes = [UInt8](data)

        let outcome = await runBlocking { () -> CmxIrohCallOutcome<Int32> in
            CmxIrohByteTransport.withErrorBuffer { kindPtr, errBuf, cap in
                bytes.withUnsafeBufferPointer { bytePointer in
                    cmux_iroh_connection_send(
                        connectionBox.value,
                        bytePointer.baseAddress,
                        bytePointer.count,
                        Self.sendTimeoutMs,
                        kindPtr,
                        errBuf,
                        cap
                    )
                }
            }
        }
        if outcome.result != 0 {
            throw CmxIrohByteTransportError.sendFailed(outcome.message)
        }
    }

    /// Closes the connection handle. Idempotent.
    public func close() async {
        if didClose { return }
        didClose = true
        let connectionBox = connection.map(CmxIrohUnsafeBox.init)
        connection = nil
        _ = await runBlocking { () -> Bool in
            if let connectionBox {
                cmux_iroh_connection_close(connectionBox.value)
            }
            return true
        }
    }

    private nonisolated func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            blockingQueue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
