public import CMUXMobileCore
public import Foundation
import Dispatch
internal import CmuxIrohFFI

/// A ``CmxByteTransport`` that dials a Mac by its iroh EndpointId over a single
/// QUIC bidirectional stream (plans/feat-ios-iroh/DESIGN.md PR 3).
///
/// The actor owns the local endpoint and the dialed connection. The blocking
/// FFI calls run on a concurrent queue and bridge back through continuations, so
/// they never block the actor's executor; the FFI handles are registry-backed,
/// so `close()` can run concurrently with an in-flight `receive()`/`send()` and
/// force it to return rather than racing a free.
public actor CmxIrohByteTransport: CmxByteTransport {
    /// Default per-receive byte cap.
    public static let defaultMaximumReceiveLength = 64 * 1024
    /// Default dial deadline in milliseconds.
    public static let defaultConnectTimeoutMilliseconds: UInt64 = 15_000

    private let endpointID: String
    private let relayURL: String?
    private let directAddrs: [String]
    private let secretKey: [UInt8]?
    private let enableRelay: Bool
    private let connectTimeoutMilliseconds: UInt64
    private let maximumReceiveLength: Int

    private var endpoint: OpaquePointer?
    private var connection: OpaquePointer?
    private var didClose = false

    // Concurrent so a blocked indefinite recv on one thread does not stall a
    // concurrent close on another (the FFI's close forces the recv to return).
    private nonisolated let blockingQueue = DispatchQueue(
        label: "dev.cmux.iroh.transport",
        attributes: .concurrent
    )

    /// Creates a transport that will dial the given peer when ``connect()`` runs.
    /// - Parameters:
    ///   - endpointID: The peer Mac's z-base-32 EndpointId.
    ///   - relayURL: The peer's home relay URL hint, if known.
    ///   - directAddrs: Direct socket-address hints for holepunch-free dials.
    ///   - secretKey: The phone's 32-byte iroh secret key. When nil, a fresh
    ///     ephemeral key is generated on connect (full PR 3 supplies a stable
    ///     Keychain key so the phone has a stable EndpointId).
    ///   - enableRelay: Whether the local endpoint enables n0 relays/discovery.
    ///     Defaults to true; tests pass false for hermetic loopback dials.
    public init(
        endpointID: String,
        relayURL: String?,
        directAddrs: [String],
        secretKey: [UInt8]? = nil,
        enableRelay: Bool = true,
        connectTimeoutMilliseconds: UInt64 = CmxIrohByteTransport.defaultConnectTimeoutMilliseconds,
        maximumReceiveLength: Int = CmxIrohByteTransport.defaultMaximumReceiveLength
    ) {
        self.endpointID = endpointID
        self.relayURL = relayURL
        self.directAddrs = directAddrs
        self.secretKey = secretKey
        self.enableRelay = enableRelay
        self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
        self.maximumReceiveLength = maximumReceiveLength
    }

    /// Creates a transport for an `.iroh` `.peer` route.
    /// - Throws: ``CmxIrohByteTransportError`` when the route kind or endpoint is
    ///   not a dial-able iroh peer, or the route fails validation.
    public init(
        route: CmxAttachRoute,
        secretKey: [UInt8]? = nil,
        enableRelay: Bool = true,
        connectTimeoutMilliseconds: UInt64 = CmxIrohByteTransport.defaultConnectTimeoutMilliseconds,
        maximumReceiveLength: Int = CmxIrohByteTransport.defaultMaximumReceiveLength
    ) throws {
        try route.validate()
        guard route.kind == .iroh else {
            throw CmxIrohByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case let .peer(id, _, directAddrs, relayURL) = route.endpoint else {
            throw CmxIrohByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        self.init(
            endpointID: id,
            relayURL: relayURL,
            directAddrs: directAddrs,
            secretKey: secretKey,
            enableRelay: enableRelay,
            connectTimeoutMilliseconds: connectTimeoutMilliseconds,
            maximumReceiveLength: maximumReceiveLength
        )
    }

    /// The local endpoint's EndpointId once ``connect()`` has bound it.
    public var localEndpointID: String? {
        guard let endpoint else { return nil }
        return Self.takeString(cmux_iroh_endpoint_id(endpoint))
    }

    public func connect() async throws {
        if didClose { throw CmxIrohByteTransportError.alreadyClosed }
        if connection != nil { return }

        let key: [UInt8]
        if let secretKey {
            guard secretKey.count == Self.secretKeyLength else {
                throw CmxIrohByteTransportError.invalidSecretKey
            }
            key = secretKey
        } else {
            guard let generated = Self.generateSecretKey() else {
                throw CmxIrohByteTransportError.keyGenerationFailed
            }
            key = generated
        }

        let id = endpointID
        let relay = relayURL
        let addrs = directAddrs
        let relayEnabled = enableRelay
        let timeout = connectTimeoutMilliseconds

        let result = await runBlocking { () -> Result<CmxIrohHandles, CmxIrohByteTransportError> in
            let bind = Self.withErrorBuffer { kindPtr, errBuf, cap in
                key.withUnsafeBufferPointer { keyBuffer in
                    cmux_iroh_endpoint_bind(
                        keyBuffer.baseAddress,
                        keyBuffer.count,
                        relayEnabled,
                        false,
                        kindPtr,
                        errBuf,
                        cap
                    )
                }
            }
            guard let endpoint = bind.result else {
                return .failure(.bindFailed(bind.message))
            }
            let dial = Self.withErrorBuffer { kindPtr, errBuf, cap in
                Self.dialConnection(
                    endpoint,
                    endpointID: id,
                    relayURL: relay,
                    directAddrs: addrs,
                    timeoutMs: timeout,
                    kindPtr,
                    errBuf,
                    cap
                )
            }
            guard let connection = dial.result else {
                cmux_iroh_endpoint_close(endpoint)
                return .failure(
                    .connectFailed(dial.message, CmxIrohConnectFailureKind(rawKind: dial.errorKind))
                )
            }
            return .success(CmxIrohHandles(
                endpoint: CmxIrohUnsafeBox(endpoint),
                connection: CmxIrohUnsafeBox(connection)
            ))
        }

        switch result {
        case let .success(handles):
            endpoint = handles.endpoint.value
            connection = handles.connection.value
        case let .failure(error):
            throw error
        }
    }

    public func receive() async throws -> Data? {
        if didClose { return nil }
        guard let connection else {
            throw CmxIrohByteTransportError.notConnected
        }
        let connectionBox = CmxIrohUnsafeBox(connection)
        let capacity = maximumReceiveLength

        let outcome = await runBlocking { () -> CmxIrohReceiveOutcome in
            var buffer = [UInt8](repeating: 0, count: capacity)
            let call = Self.withErrorBuffer { kindPtr, errBuf, cap in
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
            return CmxIrohReceiveOutcome(
                count: call.result,
                message: call.message,
                buffer: buffer
            )
        }

        if outcome.count > 0 {
            return Data(outcome.buffer.prefix(outcome.count))
        }
        if outcome.count == 0 {
            return nil // clean end of stream
        }
        // A forced close races recv to a connection-lost error; surface that as
        // a normal end of stream rather than an error.
        if didClose {
            return nil
        }
        throw CmxIrohByteTransportError.receiveFailed(outcome.message)
    }

    public func send(_ data: Data) async throws {
        if didClose { throw CmxIrohByteTransportError.alreadyClosed }
        guard let connection else {
            throw CmxIrohByteTransportError.notConnected
        }
        if data.isEmpty { return }
        let connectionBox = CmxIrohUnsafeBox(connection)
        let bytes = [UInt8](data)

        let outcome = await runBlocking { () -> CmxIrohCallOutcome<Int32> in
            Self.withErrorBuffer { kindPtr, errBuf, cap in
                bytes.withUnsafeBufferPointer { bytePointer in
                    cmux_iroh_connection_send(
                        connectionBox.value,
                        bytePointer.baseAddress,
                        bytePointer.count,
                        0,
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

    public func close() async {
        if didClose { return }
        didClose = true
        let connectionBox = connection.map(CmxIrohUnsafeBox.init)
        let endpointBox = endpoint.map(CmxIrohUnsafeBox.init)
        connection = nil
        endpoint = nil
        _ = await runBlocking { () -> Bool in
            if let connectionBox {
                cmux_iroh_connection_close(connectionBox.value)
            }
            if let endpointBox {
                cmux_iroh_endpoint_close(endpointBox.value)
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

private struct CmxIrohHandles: Sendable {
    let endpoint: CmxIrohUnsafeBox<OpaquePointer>
    let connection: CmxIrohUnsafeBox<OpaquePointer>
}

private struct CmxIrohReceiveOutcome: Sendable {
    let count: Int
    let message: String
    let buffer: [UInt8]
}
