import Foundation
import IrohLib

public enum PtxTransportError: Error, Sendable {
    case pipeClosed
    case connectionClosed
    case admissionFailed(String)
}

/// Endpoint construction and dial/accept over iroh. The Ed25519 identity key
/// seeds iroh's secret key, so the remote side's QUIC-authenticated key
/// equals `identity.publicKeyData`.
public enum PtxEndpoint {
    public static var alpn: Data { Data(PtxProtocol.identifier.utf8) }

    public struct RelayAccess: Sendable {
        public var url: String
        public var authToken: String?

        public init(url: String, authToken: String? = nil) {
            self.url = url
            self.authToken = authToken
        }
    }

    /// Relay-enabled endpoint. An empty `relays` boots direct/LAN-only, which
    /// is legal: credentials can be inserted later (`rotateRelay`).
    public static func bind(
        identity: PtxIdentity, relays: [RelayAccess], loopbackOnly: Bool = false
    ) async throws -> Endpoint {
        let builder = EndpointBuilder()
        builder.applyMinimal()
        try builder.secretKey(bytes: identity.privateKeyData)
        builder.alpns(alpns: [alpn])
        if loopbackOnly {
            try builder.bindAddr(addr: "127.0.0.1:0")
        }
        if !relays.isEmpty {
            let map = RelayMap.empty()
            for relay in relays {
                try map.insert(config: RelayConfig(url: relay.url, authToken: relay.authToken))
            }
            builder.relayMode(mode: RelayMode.custom(map: map))
        }
        return try await builder.bind()
    }

    /// Rotation is insertRelay ALONE: the fork authenticates a replacement
    /// relay connection before swapping routes (make-before-break), so live
    /// sessions continue. Never removeRelay on a live relay — remove cancels
    /// the active relay actor and severs every session riding it. If the link
    /// was already dead the insert is a silent no-op, so verify with online()
    /// and only then hard-restart (remove+insert) — any relay-carried session
    /// died with the link anyway.
    public static func rotateRelay(
        endpoint: Endpoint, url: String, token: String, log: PtxEventLog
    ) async -> Bool {
        do {
            try await endpoint.insertRelay(config: RelayConfig(url: url, authToken: token))
        } catch {
            log.emit(
                PtxEventKind.credentialError, reason: "insert-failed",
                detail: ["url": url, "error": String(describing: error)])
            return false
        }
        if await onlineWithin(endpoint: endpoint, seconds: 5) {
            log.emit(PtxEventKind.credentialRotated, reason: "zero-gap", detail: ["url": url])
            return true
        }
        _ = try? await endpoint.removeRelay(url: url)
        do {
            try await endpoint.insertRelay(config: RelayConfig(url: url, authToken: token))
        } catch {
            log.emit(
                PtxEventKind.credentialError, reason: "reinsert-failed",
                detail: ["url": url, "error": String(describing: error)])
            return false
        }
        let healthy = await onlineWithin(endpoint: endpoint, seconds: 15)
        log.emit(
            healthy ? PtxEventKind.credentialRotated : PtxEventKind.credentialError,
            reason: healthy ? "hard-restart" : "relay-unreachable", detail: ["url": url])
        return healthy
    }

    /// First-wins race instead of a task group: the FFI `online()` call does
    /// not respond to cancellation, and a group would wait for it to return
    /// (possibly never, on a dead relay) before the group scope could exit.
    /// The losing online() task is left to finish on its own.
    public static func onlineWithin(endpoint: Endpoint, seconds: Int) async -> Bool {
        let once = PtxOnce()
        return await withCheckedContinuation { continuation in
            Task {
                await endpoint.online()
                if once.first() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.first() { continuation.resume(returning: false) }
            }
        }
    }

    /// The endpoint key a relay token is bound to (JWT `endpoint_id` claim).
    /// The relay refuses a wrong-key token with NO client-visible error, so
    /// callers compare this against their own key BEFORE dialing.
    public static func tokenEndpointID(_ token: String) -> Data? {
        guard let hex = tokenClaims(token)?["endpoint_id"]?.stringValue,
            hex.count % 2 == 0
        else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Epoch seconds after which the relay stops honoring the token. Dialing
    /// with an expired token makes the relay route silently dead, so callers
    /// must name expiry loudly instead of retrying into it.
    public static func tokenExpiry(_ token: String) -> Int64? {
        tokenClaims(token)?["exp"]?.intValue
    }

    private static func tokenClaims(_ token: String) -> [String: PtxJSON]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONDecoder().decode(PtxJSON.self, from: data))?.objectValue
    }

    /// Address with no direct candidates: the connection can only establish
    /// through the relay. This is the soak's relay-only mode.
    public static func relayOnlyAddr(id: Data, relayURL: String) throws -> EndpointAddr {
        EndpointAddr(id: try EndpointId.fromBytes(bytes: id), relayUrl: relayURL, addresses: [])
    }

    public static func addr(
        id: Data, relayURL: String?, directAddresses: [String]
    ) throws -> EndpointAddr {
        EndpointAddr(
            id: try EndpointId.fromBytes(bytes: id), relayUrl: relayURL,
            addresses: directAddresses)
    }

    public static func directAddr(of endpoint: Endpoint) -> EndpointAddr {
        let addresses = endpoint.boundSockets().map {
            $0.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
        }
        return EndpointAddr(id: endpoint.id(), relayUrl: nil, addresses: addresses)
    }

    public static func dial(
        endpoint: Endpoint, to addr: EndpointAddr, log: PtxEventLog
    ) async throws -> PtxConnection {
        let start = ContinuousClock.now
        let connection: Connection
        do {
            connection = try await endpoint.connect(addr: addr, alpn: alpn)
        } catch {
            log.emit(
                PtxEventKind.dialFailed, peer: addr.id().toBytes(),
                reason: "quic-connect", ms: log.elapsedMs(since: start),
                detail: [
                    "error": String(describing: error),
                    "relay": addr.relayUrl() ?? "none",
                    "addrs": String(addr.directAddresses().count),
                ])
            throw error
        }
        log.emit(
            PtxEventKind.dialConnected, peer: connection.remoteId().toBytes(),
            ms: log.elapsedMs(since: start),
            detail: ["relay": addr.relayUrl() ?? "none"])
        let peer = PtxConnection(connection: connection, role: .dialer, log: log)
        await peer.start()
        return peer
    }

    /// Pull and complete the next incoming connection; nil once the endpoint
    /// is closed.
    public static func acceptOne(endpoint: Endpoint, log: PtxEventLog) async throws
        -> PtxConnection?
    {
        guard let incoming = await endpoint.acceptNext() else { return nil }
        let accepting = try await incoming.accept()
        let connection = try await accepting.connect()
        let peer = PtxConnection(connection: connection, role: .acceptor, log: log)
        await peer.start()
        return peer
    }
}

/// One live QUIC connection. The control lane is a framed stream; every other
/// stream is raw bytes after a one-frame `raw.open {descriptor}` handshake.
/// Both roles run the accept loop (the host opens server-event streams toward
/// the phone).
public actor PtxConnection {
    public enum Role: Sendable { case dialer, acceptor }

    static let ctlOpenType = "ctl.open"
    static let rawOpenType = "raw.open"

    private let connection: Connection
    private let role: Role
    private let log: PtxEventLog
    private let remoteKey: Data
    private var ctlLane: PtxFrameChannel?
    private var ctlWaiters: [CheckedContinuation<PtxFrameChannel?, Never>] = []
    private var rawStreamHandler: (@Sendable (String, PtxRawStream) async -> Void)?
    private var pendingRawStreams: [(String, PtxRawStream)] = []
    private var acceptLoop: Task<Void, Never>?
    private var closedFlag = false
    private var localReason: String?

    init(connection: Connection, role: Role, log: PtxEventLog) {
        self.connection = connection
        self.role = role
        self.log = log
        self.remoteKey = connection.remoteId().toBytes()
    }

    /// iroh authenticates the remote endpoint key during the QUIC handshake;
    /// admission judges grants against THIS key.
    public nonisolated var authenticatedRemoteKey: Data { remoteKey }

    public var isClosed: Bool {
        closedFlag || connection.closeReason() != nil
    }

    public func start() {
        guard acceptLoop == nil else { return }
        acceptLoop = Task { await self.runAcceptLoop() }
    }

    /// Dialer side: opens the framed control lane (first stream).
    public func openControlLane() async throws -> PtxFrameChannel {
        guard !closedFlag else { throw PtxTransportError.connectionClosed }
        let stream = try await connection.openBi()
        let channel = PtxFrameChannel(send: stream.send(), recv: stream.recv())
        try await channel.sendFrame(PtxFrame(type: Self.ctlOpenType))
        ctlLane = channel
        return channel
    }

    /// Acceptor side: waits for the peer's control lane.
    public func acceptedControlLane() async -> PtxFrameChannel? {
        if let ctlLane { return ctlLane }
        if closedFlag { return nil }
        return await withCheckedContinuation { continuation in
            if let existing = ctlLane {
                continuation.resume(returning: existing)
            } else if closedFlag {
                continuation.resume(returning: nil)
            } else {
                ctlWaiters.append(continuation)
            }
        }
    }

    /// Registers the single owner of inbound raw streams; arrivals before
    /// registration are delivered immediately, in order.
    public func onRawStream(
        _ handler: @escaping @Sendable (String, PtxRawStream) async -> Void
    ) {
        rawStreamHandler = handler
        for (descriptor, stream) in pendingRawStreams {
            Task { await handler(descriptor, stream) }
        }
        pendingRawStreams.removeAll()
    }

    /// Opens one raw stream: one handshake frame carries the descriptor;
    /// every byte after it belongs to the caller.
    public func openRawStream(descriptor: String) async throws -> PtxRawStream {
        guard !closedFlag else { throw PtxTransportError.connectionClosed }
        let stream = try await connection.openBi()
        let channel = PtxFrameChannel(send: stream.send(), recv: stream.recv())
        try await channel.sendFrame(
            PtxFrame(type: Self.rawOpenType, payload: ["d": .string(descriptor)]))
        log.emit(
            PtxEventKind.laneOpened, peer: remoteKey,
            detail: ["descriptor": descriptor, "direction": "out"])
        return PtxRawStream(send: stream.send(), recv: stream.recv(), buffered: Data())
    }

    /// Deliberate close: the reason rides the QUIC CONNECTION_CLOSE bytes,
    /// which the protocol retransmits during shutdown. No drains, no sleeps.
    public func close(reason: String?) async {
        guard !closedFlag else { return }
        closedFlag = true
        localReason = reason
        acceptLoop?.cancel()
        log.emit(
            PtxEventKind.sessionEnd, peer: remoteKey,
            reason: reason ?? "local-close",
            detail: ["initiator": "local"])
        try? connection.close(
            errorCode: reason == nil ? 0 : 1,
            reason: Data((reason ?? "closed").utf8))
        resumeWaitersClosed()
    }

    private static let knownReasonCodes: [String] =
        (PtxDenial.allCases.map(\.rawValue) + PtxCloseReason.allCases.map(\.rawValue))
        .sorted { $0.count > $1.count }

    /// Resolves once the connection's close cause is known. Await only after
    /// observing stream EOF (or to watch for death). Parses our reason codes
    /// back out of the rendered close cause, longest-first.
    public func termination() async -> String? {
        if let localReason { return localReason }
        let rendered: String
        if let reason = connection.closeReason() {
            rendered = reason
        } else if closedFlag {
            return nil
        } else {
            rendered = await connection.closed()
        }
        for code in Self.knownReasonCodes where rendered.contains(code) {
            return code
        }
        return rendered.isEmpty ? nil : "unattributed:\(rendered.prefix(120))"
    }

    private func runAcceptLoop() async {
        while true {
            do {
                let stream = try await connection.acceptBi()
                let channel = PtxFrameChannel(send: stream.send(), recv: stream.recv())
                guard let open = await channel.receiveFrame() else { continue }
                if open.type == Self.ctlOpenType {
                    ctlLane = channel
                    for waiter in ctlWaiters {
                        waiter.resume(returning: channel)
                    }
                    ctlWaiters.removeAll()
                    continue
                }
                if open.type == Self.rawOpenType {
                    let descriptor = open.payload["d"]?.stringValue ?? ""
                    let raw = PtxRawStream(
                        send: stream.send(), recv: stream.recv(),
                        buffered: await channel.drainBufferedBytes())
                    log.emit(
                        PtxEventKind.laneOpened, peer: remoteKey,
                        detail: [
                            "descriptor": descriptor, "direction": "in",
                            "remainder": String(raw.handshakeRemainder.count),
                        ])
                    if let handler = rawStreamHandler {
                        Task { await handler(descriptor, raw) }
                    } else {
                        pendingRawStreams.append((descriptor, raw))
                    }
                    continue
                }
                log.emit(
                    PtxEventKind.frameError, peer: remoteKey,
                    reason: "unexpected-open-frame", detail: ["type": open.type])
            } catch {
                closedFlag = true
                if localReason == nil {
                    log.emit(
                        PtxEventKind.sessionEnd, peer: remoteKey,
                        reason: "accept-loop-ended",
                        detail: [
                            "initiator": "remote-or-network",
                            "error": String(describing: error),
                        ])
                }
                resumeWaitersClosed()
                return
            }
        }
    }

    private func resumeWaitersClosed() {
        for waiter in ctlWaiters {
            waiter.resume(returning: nil)
        }
        ctlWaiters.removeAll()
    }
}

/// Serializes stream I/O and reassembles frames from arbitrary QUIC reads.
public actor PtxFrameChannel {
    private let sendStream: SendStream
    private let recvStream: RecvStream
    private var decoder = PtxFrameDecoder()
    private var eof = false
    private let encoder = PtxFrameEncoder()

    init(send: SendStream, recv: RecvStream) {
        self.sendStream = send
        self.recvStream = recv
    }

    public func sendFrame(_ frame: PtxFrame) async throws {
        let data = try encoder.encode(frame)
        do {
            try await sendStream.writeAll(buf: data)
        } catch {
            throw PtxTransportError.pipeClosed
        }
    }

    public func receiveFrame() async -> PtxFrame? {
        while !eof {
            do {
                if let frame = try decoder.next() { return frame }
                let data = try await recvStream.read(sizeLimit: 1 << 16)
                if data.isEmpty {
                    eof = true
                    break
                }
                decoder.feed(data)
            } catch {
                eof = true
            }
        }
        return nil
    }

    /// Bytes buffered past the handshake frame on a raw stream. The decoder
    /// never parses past the frame it returned, so these are the peer's raw
    /// payload verbatim, re-injected as the raw stream's head.
    func drainBufferedBytes() -> Data {
        decoder.drainRemainder()
    }

    public func finish() async {
        try? await sendStream.finish()
    }
}

/// One raw application stream: unframed QUIC bytes with bounded reads,
/// backpressured writes, and half-close in both directions. The handshake
/// remainder (if any) must be served before live stream bytes; consumers
/// seed their read buffer with it.
public struct PtxRawStream: Sendable {
    let send: SendStream
    let recv: RecvStream
    let buffered: Data

    public var handshakeRemainder: Data { buffered }

    /// Reads at most `maximumByteCount`; nil on clean peer finish. Callers
    /// pass their own buffer seeded with `handshakeRemainder`.
    public func read(maximumByteCount: Int, consumedBuffer: inout Data) async throws -> Data? {
        if !consumedBuffer.isEmpty {
            let chunk = consumedBuffer.prefix(maximumByteCount)
            consumedBuffer.removeFirst(chunk.count)
            return Data(chunk)
        }
        let data = try await recv.read(sizeLimit: UInt32(clamping: maximumByteCount))
        return data.isEmpty ? nil : data
    }

    public func write(_ data: Data) async throws {
        try await send.writeAll(buf: data)
    }

    public func setSendPriority(_ priority: Int32) async throws {
        try await send.setPriority(p: priority)
    }

    public func finishSend() async throws {
        try await send.finish()
    }

    public func stopReceiving(errorCode: UInt64) async {
        try? await recv.stop(errorCode: errorCode)
    }

    public func resetSend(errorCode: UInt64) async {
        try? await send.reset(errorCode: errorCode)
    }
}
