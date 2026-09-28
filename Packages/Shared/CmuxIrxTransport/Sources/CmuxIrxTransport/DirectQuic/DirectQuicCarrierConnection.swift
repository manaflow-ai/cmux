import CryptoKit
public import Foundation
public import Network
import Security

/// irx's carrier over Network.framework QUIC to one exact host and port.
///
/// There is no relay, discovery, or NAT traversal. After TLS completes, both
/// sides sign the connection's TLS exporter with their Ed25519 device keys
/// (the same keys Iroh uses as EndpointIDs), so the peer key irx admission
/// judges is authenticated end to end even though the TLS certificate is not.
public final class DirectQuicCarrierConnection: IrxCarrierConnection, @unchecked Sendable {
    private enum Role { case client, server }

    private let group: NWConnectionGroup
    private let queue: DispatchQueue
    private let role: Role
    private let lock = NSLock()
    private var peerEndpointIDHex = ""
    private var readyWaiter: CheckedContinuation<Void, any Error>?
    private var isReady = false
    private var cause: String?
    private var closeWaiters: [CheckedContinuation<String, Never>] = []
    private let bidirectional = DirectQuicInbox()
    private let unidirectional = DirectQuicInbox()
    private let handshakeStreams = DirectQuicInbox()

    /// Identifies this connection for continuity checks. Random, because
    /// Network.framework exposes no connection-level identifier of its own.
    public let stableID = UInt64.random(in: 1 ... UInt64.max)
    private var onAdmissionSettled: (@Sendable () -> Void)?
    private var admissionSettled = false

    /// Lowercase hex Ed25519 device key the handshake proved; empty until
    /// the handshake completes.
    public var remoteEndpointIDHex: String { lock.withLock { peerEndpointIDHex } }

    private init(group: NWConnectionGroup, role: Role, queue: DispatchQueue) {
        self.group = group
        self.role = role
        self.queue = queue
    }

    // MARK: Establishment

    /// Dials `host:port` and authenticates the Mac as `expectedEndpointIDHex`.
    public static func dial(
        host: String,
        port: UInt16,
        identity: IrxIdentity,
        expectedEndpointIDHex: String,
        requiredInterface: NWInterface? = nil,
        deadline: Duration = .seconds(10)
    ) async throws -> DirectQuicCarrierConnection {
        guard !host.isEmpty, port != 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw DirectQuicError.invalidEndpoint
        }
        let options = makeOptions()
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
            // Identity is proven by the exporter-bound device signatures below.
            complete(true)
        }, DispatchQueue.global(qos: .userInitiated))
        let parameters = NWParameters(quic: options)
        if let requiredInterface { parameters.requiredInterface = requiredInterface }
        let queue = DispatchQueue(label: "cmux.direct-quic.client")
        let group = NWConnectionGroup(
            with: NWMultiplexGroup(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort)),
            using: parameters)
        let carrier = DirectQuicCarrierConnection(group: group, role: .client, queue: queue)
        do {
            let result = try await withIrxDeadlineResult(deadline) {
                try await carrier.start()
                try await carrier.clientHandshake(identity: identity, expected: expectedEndpointIDHex.lowercased())
                return true
            }
            guard case .operation(true) = result else {
                throw DirectQuicError.handshakeFailed("timed out")
            }
        } catch {
            carrier.close(errorCode: 1, reason: IrxCloseCode.admissionTimeout.reasonData)
            throw error
        }
        return carrier
    }

    /// Adopts an inbound connection group and authenticates the dialer.
    static func accept(
        group: NWConnectionGroup,
        identity: IrxIdentity,
        deadline: Duration
    ) async throws -> DirectQuicCarrierConnection {
        let carrier = DirectQuicCarrierConnection(
            group: group, role: .server, queue: DispatchQueue(label: "cmux.direct-quic.server"))
        do {
            let result = try await withIrxDeadlineResult(deadline) {
                try await carrier.start()
                try await carrier.serverHandshake(identity: identity)
                return true
            }
            guard case .operation(true) = result else {
                throw DirectQuicError.handshakeFailed("timed out")
            }
        } catch {
            carrier.close(errorCode: 1, reason: IrxCloseCode.admissionTimeout.reasonData)
            throw error
        }
        return carrier
    }

    /// The QUIC options both the dialer and the listener build from, so the
    /// two sides always negotiate the same ALPN, timeouts, and stream budget.
    static func makeOptions() -> NWProtocolQUIC.Options {
        let wire = DirectQuicProtocol()
        let options = NWProtocolQUIC.Options(alpn: [wire.alpn])
        options.idleTimeout = wire.idleTimeoutMilliseconds
        options.initialMaxStreamsBidirectional = wire.maximumStreams
        options.initialMaxStreamsUnidirectional = 0
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        return options
    }

    private func start() async throws {
        group.newConnectionHandler = { [weak self] connection in
            self?.adoptInbound(connection)
        }
        group.stateUpdateHandler = { [weak self] state in
            self?.groupStateChanged(state)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resolved: Result<Void, any Error>? = lock.withLock {
                    if let cause { return .failure(DirectQuicError.connectionClosed(cause)) }
                    if isReady { return .success(()) }
                    readyWaiter = continuation
                    return nil
                }
                if let resolved { continuation.resume(with: resolved) }
                if resolved == nil, group.state == .setup { group.start(queue: queue) }
            }
        } onCancel: {
            self.close(errorCode: 1, reason: IrxCloseCode.admissionTimeout.reasonData)
        }
    }

    private func groupStateChanged(_ state: NWConnectionGroup.State) {
        switch state {
        case .ready:
            if let metadata = group.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata {
                metadata.keepAlive = .seconds(DirectQuicProtocol().keepAliveSeconds)
            }
            let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                isReady = true
                defer { readyWaiter = nil }
                return readyWaiter
            }
            waiter?.resume()
        case let .failed(error):
            finish(cause: "direct-quic transport failed: \(error)")
        case .cancelled:
            finish(cause: "direct-quic connection cancelled")
        default:
            // `.waiting` is transient (Network.framework reports it briefly
            // even on loopback); the dial deadline bounds an unreachable path.
            break
        }
    }

    // MARK: Device-key handshake

    private func exporter() throws -> Data {
        guard let metadata = group.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata else {
            throw DirectQuicError.handshakeFailed("missing QUIC metadata")
        }
        let label = "EXPORTER-cmux-direct-quic-v1"
        guard let secret = label.withCString({
            sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata, label.utf8.count, $0, 32)
        }) else {
            throw DirectQuicError.handshakeFailed("missing TLS exporter")
        }
        return Data(secret as DispatchData)
    }

    /// The exporter-bound bytes each side signs with its Ed25519 device key.
    static func signedMessage(role: String, exporter: Data) -> Data {
        Data("\(DirectQuicProtocol().alpn) \(role) key proof".utf8) + exporter
    }

    private func clientHandshake(identity: IrxIdentity, expected: String) async throws {
        let exporter = try exporter()
        let stream = try await DirectQuicStream.open(in: group, kind: .handshake, queue: queue)
        let proof = try identity.sign(Self.signedMessage(role: "client", exporter: exporter))
        try await stream.writeAll(identity.publicKeyData + proof)
        let reply = try await stream.readExactly(96)
        let serverKey = reply.prefix(32)
        guard serverKey.hexString == expected else { throw DirectQuicError.peerIdentityMismatch }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: serverKey),
              key.isValidSignature(reply.suffix(64), for: Self.signedMessage(role: "server", exporter: exporter))
        else { throw DirectQuicError.handshakeFailed("invalid server proof") }
        try? await stream.finish()
        try? await stream.stop(errorCode: 0)
        lock.withLock { peerEndpointIDHex = expected }
    }

    private func serverHandshake(identity: IrxIdentity) async throws {
        let exporter = try exporter()
        let stream = try await handshakeStreams.next()
        let hello = try await stream.readExactly(96)
        let clientKey = hello.prefix(32)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: clientKey),
              key.isValidSignature(hello.suffix(64), for: Self.signedMessage(role: "client", exporter: exporter))
        else { throw DirectQuicError.handshakeFailed("invalid client proof") }
        let proof = try identity.sign(Self.signedMessage(role: "server", exporter: exporter))
        try await stream.writeAll(identity.publicKeyData + proof)
        try? await stream.finish()
        try? await stream.stop(errorCode: 0)
        lock.withLock { peerEndpointIDHex = clientKey.hexString }
        // Only one handshake per connection.
        handshakeStreams.finish()
    }

    // MARK: Inbound streams

    private func adoptInbound(_ connection: NWConnection) {
        let stream = DirectQuicStream(connection)
        connection.start(queue: queue)
        Task { [weak self] in
            guard let self else { return }
            guard let kindByte = try? await stream.readExactly(1).first,
                  let kind = DirectQuicProtocol.StreamKind(rawValue: kindByte) else {
                try? await stream.reset(errorCode: 2)
                return
            }
            let authenticated = !remoteEndpointIDHex.isEmpty
            switch kind {
            case .handshake:
                if !handshakeStreams.offer(stream) { try? await stream.reset(errorCode: 2) }
            case .bidirectional where authenticated:
                if !bidirectional.offer(stream) { try? await stream.reset(errorCode: 2) }
            case .unidirectional where authenticated:
                stream.abandon(send: true)
                if !unidirectional.offer(stream) { try? await stream.reset(errorCode: 2) }
            case .close:
                // Length-prefixed: the sender cancels the connection right
                // after writing, so the stream's FIN may never arrive.
                let length = (try? await stream.readExactly(1)).flatMap(\.first).map(Int.init) ?? 0
                let reason = length > 0 ? ((try? await stream.readExactly(length)) ?? Data()) : Data()
                finish(cause: "remote close: " + String(decoding: reason, as: UTF8.self))
                group.cancel()
            case .bidirectional, .unidirectional:
                // Application lanes before the device-key handshake are refused.
                try? await stream.reset(errorCode: 2)
            }
        }
    }

    // MARK: IrxCarrierConnection

    /// Opens an outbound two-way lane; both halves are one QUIC stream.
    public func openBi() async throws -> (send: any IrxCarrierSendStream, recv: any IrxCarrierRecvStream) {
        try throwIfClosed()
        let stream = try await DirectQuicStream.open(in: group, kind: .bidirectional, queue: queue)
        return (stream, stream)
    }

    /// Opens an outbound one-way lane: a bidirectional stream whose receive
    /// half this side abandons (see `DirectQuicProtocol.StreamKind`).
    public func openUni() async throws -> any IrxCarrierSendStream {
        try throwIfClosed()
        let stream = try await DirectQuicStream.open(in: group, kind: .unidirectional, queue: queue)
        stream.abandon(send: false)
        return stream
    }

    /// The next inbound two-way lane, in arrival order.
    public func acceptBi() async throws -> (send: any IrxCarrierSendStream, recv: any IrxCarrierRecvStream) {
        let stream = try await bidirectional.next()
        return (stream, stream)
    }

    /// The next inbound one-way lane, in arrival order.
    public func acceptUni() async throws -> any IrxCarrierRecvStream {
        try await unidirectional.next()
    }

    /// Registers the exactly-once release of this connection's listener
    /// admission slot. Fires immediately when the connection already settled
    /// (it died between accept and registration), so a slot can never leak.
    func setOnAdmissionSettled(_ callback: @escaping @Sendable () -> Void) {
        let fireNow = lock.withLock { () -> Bool in
            if admissionSettled { return true }
            onAdmissionSettled = callback
            return false
        }
        if fireNow { callback() }
    }

    /// Releases the listener admission slot held since accept: called on the
    /// irx admission verdict, and by connection teardown so a dead
    /// connection frees its slot. Idempotent.
    public func settleAdmission() {
        let fire = lock.withLock { () -> (@Sendable () -> Void)?? in
            guard !admissionSettled else { return nil }
            admissionSettled = true
            defer { onAdmissionSettled = nil }
            return .some(onAdmissionSettled)
        }
        if case let .some(callback) = fire { callback?() }
    }

    /// The rendered close cause already published, without waiting.
    public func closeReason() -> String? { lock.withLock { cause } }

    /// Waits for the connection to end and returns the rendered cause.
    public func closed() async -> String {
        await withCheckedContinuation { continuation in
            let resolved: String? = lock.withLock {
                if let cause { return cause }
                closeWaiters.append(continuation)
                return nil
            }
            if let resolved { continuation.resume(returning: resolved) }
        }
    }

    /// QUIC CONNECTION_CLOSE reasons do not reach Network.framework peers
    /// promptly, so the reason travels on its own stream before the close.
    public func close(errorCode: UInt64, reason: Data) {
        let wasOpen = lock.withLock { cause == nil && isReady }
        finish(cause: "local close: " + String(decoding: reason, as: UTF8.self))
        guard wasOpen else {
            group.cancel()
            return
        }
        let group = group
        let queue = queue
        Task {
            if let stream = try? await DirectQuicStream.open(in: group, kind: .close, queue: queue) {
                let bounded = reason.prefix(255)
                try? await stream.writeAll(Data([UInt8(bounded.count)]) + bounded)
            }
            group.cancel()
        }
    }

    /// A no-op: the stream budget is fixed in `makeOptions` at connect time,
    /// and Network.framework cannot raise it afterwards.
    public func setMaxConcurrentStreams(bi: UInt64, uni: UInt64) {}

    /// A no-op: Direct QUIC never relays, so there is no traversal to allow.
    public func authorizeNatTraversal() async throws {}

    /// Always direct; the carrier dials one exact host and port.
    public func selectedPath() -> (kind: IrxCarrierPathKind, description: String) {
        (.direct, "direct-quic:\(group.descriptor)")
    }

    private func throwIfClosed() throws {
        if let cause = closeReason() { throw DirectQuicError.connectionClosed(cause) }
    }

    private func finish(cause newCause: String) {
        let (readyWaiter, waiters, published) = lock.withLock {
            () -> (CheckedContinuation<Void, any Error>?, [CheckedContinuation<String, Never>], String) in
            if cause == nil { cause = newCause }
            let ready = self.readyWaiter
            self.readyWaiter = nil
            let waiters = closeWaiters
            closeWaiters.removeAll()
            return (ready, waiters, cause ?? newCause)
        }
        readyWaiter?.resume(throwing: DirectQuicError.connectionClosed(published))
        for waiter in waiters { waiter.resume(returning: published) }
        settleAdmission()
        bidirectional.finish()
        unidirectional.finish()
        handshakeStreams.finish()
    }
}
