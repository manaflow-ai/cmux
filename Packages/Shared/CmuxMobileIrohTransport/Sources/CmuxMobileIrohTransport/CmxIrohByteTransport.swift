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
    private let relayAuthToken: String?
    private let directAddrs: [String]
    private let secretKey: [UInt8]?
    private let enableRelay: Bool
    private let relayOnly: Bool
    private let connectTimeoutMilliseconds: UInt64
    private let maximumReceiveLength: Int

    private var endpoint: OpaquePointer?
    private var stream: CmxIrohByteStream?
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
    ///   - relayURL: The peer's home relay URL hint, if known. When a non-empty
    ///     `relayAuthToken` is also supplied, the local endpoint authenticates
    ///     to this relay through its bind-time custom relay map.
    ///   - relayAuthToken: An optional token that authenticates the local
    ///     endpoint to the custom relay at bind time. It is never used as a
    ///     per-dial hint or logged.
    ///   - directAddrs: Direct socket-address hints for holepunch-free dials.
    ///   - secretKey: The phone's 32-byte iroh secret key. When nil, a fresh
    ///     ephemeral key is generated on connect (full PR 3 supplies a stable
    ///     Keychain key so the phone has a stable EndpointId).
    ///   - enableRelay: Whether the local endpoint enables n0 relays/discovery.
    ///     Defaults to true; tests pass false for hermetic loopback dials.
    ///   - relayOnly: Whether the dialer disables local IP transports and dials
    ///     with relay hints only. Defaults to false.
    ///   - connectTimeoutMilliseconds: The deadline for dialing the peer.
    ///   - maximumReceiveLength: The maximum bytes returned by one receive.
    public init(
        endpointID: String,
        relayURL: String?,
        relayAuthToken: String? = nil,
        directAddrs: [String],
        secretKey: [UInt8]? = nil,
        enableRelay: Bool = true,
        relayOnly: Bool = false,
        connectTimeoutMilliseconds: UInt64 = CmxIrohByteTransport.defaultConnectTimeoutMilliseconds,
        maximumReceiveLength: Int = CmxIrohByteTransport.defaultMaximumReceiveLength
    ) {
        self.endpointID = endpointID
        self.relayURL = relayURL
        self.relayAuthToken = relayAuthToken
        self.directAddrs = directAddrs
        self.secretKey = secretKey
        self.enableRelay = enableRelay
        self.relayOnly = relayOnly
        self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
        self.maximumReceiveLength = maximumReceiveLength
    }

    /// Creates a transport for an `.iroh` `.peer` route.
    /// - Parameters:
    ///   - route: The peer route to dial.
    ///   - relayAuthToken: An optional token for authenticating the local
    ///     endpoint to the route's custom relay at bind time.
    ///   - secretKey: The phone's stable iroh secret key, or nil for an
    ///     ephemeral key.
    ///   - enableRelay: Whether the local endpoint enables relays and discovery.
    ///   - relayOnly: Whether the dialer disables local IP transports.
    ///   - connectTimeoutMilliseconds: The deadline for dialing the peer.
    ///   - maximumReceiveLength: The maximum bytes returned by one receive.
    /// - Throws: ``CmxIrohByteTransportError`` when the route kind or endpoint is
    ///   not a dial-able iroh peer, or the route fails validation.
    public init(
        route: CmxAttachRoute,
        relayAuthToken: String? = nil,
        secretKey: [UInt8]? = nil,
        enableRelay: Bool = true,
        relayOnly: Bool = false,
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
            relayAuthToken: relayAuthToken,
            directAddrs: directAddrs,
            secretKey: secretKey,
            enableRelay: enableRelay,
            relayOnly: relayOnly,
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
        if stream != nil { return }

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
        let relayAuth = relayAuthToken
        // Preserve the existing default-map bind when no token is available;
        // a non-empty token makes the peer relay the local authenticated map.
        let bindRelay = relayAuth?.isEmpty == false ? relay : nil
        let addrs = directAddrs
        let relayEnabled = enableRelay
        let relayOnlyDial = relayOnly
        let timeout = connectTimeoutMilliseconds

        let result = await runBlocking { () -> Result<CmxIrohHandles, CmxIrohByteTransportError> in
            let bind = Self.withErrorBuffer { kindPtr, errBuf, cap in
                Self.bindEndpoint(
                    key: key,
                    enableRelay: relayEnabled,
                    relayURL: bindRelay,
                    relayAuthToken: relayAuth,
                    relayOnly: relayOnlyDial,
                    acceptConnections: false,
                    kindPtr,
                    errBuf,
                    cap
                )
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
                    relayOnly: relayOnlyDial,
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
            if didClose || Task.isCancelled {
                let endpointBox = handles.endpoint
                let connectionBox = handles.connection
                _ = await runBlocking { () -> Bool in
                    cmux_iroh_connection_close(connectionBox.value)
                    cmux_iroh_endpoint_close(endpointBox.value)
                    return true
                }
                if didClose {
                    throw CmxIrohByteTransportError.alreadyClosed
                }
                throw CancellationError()
            }
            endpoint = handles.endpoint.value
            let openedStream = CmxIrohByteStream(
                connection: handles.connection.value,
                maximumReceiveLength: maximumReceiveLength
            )
            stream = openedStream
            let pathKind = await openedStream.connectionPathKind()
            Self.diagnosticLogger.info("iroh path=\(pathKind, privacy: .public)")
        case let .failure(error):
            throw error
        }
    }

    public func connectionPathKind() async -> String {
        guard let stream else { return "unknown" }
        return await stream.connectionPathKind()
    }

    public func connectionDiagnostics() async -> CmxConnectionDiagnostics? {
        guard let stream else {
            return CmxConnectionDiagnostics(
                transportKind: .iroh,
                pathKind: .unknown,
                relayLabel: Self.relayLabel(for: relayURL),
                remoteEndpointId: endpointID.isEmpty ? nil : endpointID
            )
        }
        return await stream.connectionDiagnostics(relayHint: relayURL)
    }

    public func receive() async throws -> Data? {
        if didClose { return nil }
        guard let stream else {
            throw CmxIrohByteTransportError.notConnected
        }
        return try await stream.receive()
    }

    public func send(_ data: Data) async throws {
        if didClose { throw CmxIrohByteTransportError.alreadyClosed }
        guard let stream else {
            throw CmxIrohByteTransportError.notConnected
        }
        try await stream.send(data)
    }

    public func close() async {
        if didClose { return }
        didClose = true
        let openStream = stream
        let endpointBox = endpoint.map(CmxIrohUnsafeBox.init)
        stream = nil
        endpoint = nil
        await openStream?.close()
        _ = await runBlocking { () -> Bool in
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
