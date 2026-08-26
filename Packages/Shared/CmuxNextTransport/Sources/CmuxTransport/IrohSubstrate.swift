import Foundation
import IrohLib

/// The iroh-mode substrate (contract 2.1, D7 rung 1): real QUIC connections
/// via stock upstream iroh (cmux-lite IrohLib branch), plugged into the same
/// `PeerConnection` seam the loopback implements. Lanes map one-to-one onto
/// bidirectional QUIC streams, so cross-lane independence (5.2) is physical.
public enum IrohSubstrate {
    public static var alpn: Data { Data(CmuxPeerProtocol.identifier.utf8) }

    /// Build and bind an endpoint whose network identity IS the peer identity
    /// (contract 1.1): the Ed25519 key seeds iroh's secret key, so the remote
    /// side's substrate-authenticated key equals `identity.publicKeyData`.
    /// `minimalLoopback` binds to 127.0.0.1 with no relays and no discovery,
    /// for in-process live-QUIC tests; the relay-fleet configuration is P1e.
    public static func endpoint(
        identity: PeerIdentity, minimalLoopback: Bool
    ) async throws -> Endpoint {
        let builder = EndpointBuilder()
        builder.applyMinimal()
        try builder.secretKey(bytes: identity.privateKeyData)
        builder.alpns(alpns: [alpn])
        if minimalLoopback {
            try builder.bindAddr(addr: "127.0.0.1:0")
        }
        let endpoint = try await builder.bind()
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                endpoint bound id=\(TransportDebugLog.hex8(endpoint.id().toBytes()), privacy: .public) \
                device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                relays=0 loopback=\(minimalLoopback, privacy: .public) \
                sockets=\(endpoint.boundSockets().count, privacy: .public)
                """)
        }
        return endpoint
    }

    /// One authenticated relay (contract 9.1): our fleet requires an
    /// endpoint-bound token on the websocket upgrade. Rotation: `insertRelay`
    /// ALONE with the fresh token — our iroh fork authenticates a replacement
    /// connection before swapping routes, so live sessions continue
    /// (make-before-break). Never removeRelay first: remove cancels the
    /// active relay immediately and severs every session riding it.
    public struct RelayAccess: Sendable {
        public var url: String
        public var quicPort: UInt16?
        public var authToken: String?

        public init(url: String, quicPort: UInt16? = nil, authToken: String? = nil) {
            self.url = url
            self.quicPort = quicPort
            self.authToken = authToken
        }
    }

    /// Relay-enabled endpoint (P1e): identity-seeded like the loopback
    /// variant, but with a custom relay map pointing at our fleet.
    public static func endpoint(
        identity: PeerIdentity, relays: [RelayAccess]
    ) async throws -> Endpoint {
        let builder = EndpointBuilder()
        builder.applyMinimal()
        try builder.secretKey(bytes: identity.privateKeyData)
        builder.alpns(alpns: [alpn])
        let map = RelayMap.empty()
        for relay in relays {
            try map.insert(
                config: RelayConfig(
                    url: relay.url, quicPort: relay.quicPort, authToken: relay.authToken))
        }
        builder.relayMode(mode: RelayMode.custom(map: map))
        let endpoint = try await builder.bind()
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                endpoint bound id=\(TransportDebugLog.hex8(endpoint.id().toBytes()), privacy: .public) \
                device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                relays=\(relays.count, privacy: .public) \
                relayUrls=\(relays.map(\.url).joined(separator: ","), privacy: .public) \
                sockets=\(endpoint.boundSockets().count, privacy: .public)
                """)
        }
        return endpoint
    }

    /// The endpoint key a fleet token is bound to (its JWT `endpoint_id`
    /// claim), or nil if the token doesn't parse. Deterministic and offline.
    /// The relay refuses a wrong-key token with NO client-visible error (the
    /// route just looks dead), so callers must compare this against their own
    /// `identity.publicKeyData` BEFORE dialing and say so loudly on mismatch.
    public static func tokenEndpointId(_ token: String) -> Data? {
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

    /// When a fleet token stops being honored (its JWT `exp` claim, epoch
    /// seconds), or nil if it doesn't parse. Tokens live 300s; dialing with
    /// an expired one makes the relay route silently dead, so callers should
    /// name it (the 08-21 "chat died at +5min" field bite).
    public static func tokenExpiry(_ token: String) -> Int64? {
        tokenClaims(token)?["exp"]?.intValue
    }

    private static func tokenClaims(_ token: String) -> [String: JSONValue]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
    }

    /// A relay-only address: no direct candidates at all, so the connection
    /// can only be established through the relay (harness spec 2.2).
    public static func relayAddr(id: Data, relayUrl: String) throws -> EndpointAddr {
        EndpointAddr(id: try EndpointId.fromBytes(bytes: id), relayUrl: relayUrl, addresses: [])
    }

    /// The dialable address of a bound endpoint, for tests and LAN dials.
    public static func directAddr(of endpoint: Endpoint) -> EndpointAddr {
        let addresses = endpoint.boundSockets().map {
            $0.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
        }
        return EndpointAddr(id: endpoint.id(), relayUrl: nil, addresses: addresses)
    }

    public static func dial(
        endpoint: Endpoint, to addr: EndpointAddr
    ) async throws -> IrohPeerConnection {
        let dialStart = ContinuousClock.now
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                substrate dial begin target=\(TransportDebugLog.hex8(addr.id().toBytes()), privacy: .public) \
                addrs=\(addr.directAddresses().count, privacy: .public) \
                relay=\(addr.relayUrl() ?? "none", privacy: .public)
                """)
        }
        let connection: Connection
        do {
            connection = try await endpoint.connect(addr: addr, alpn: alpn)
        } catch {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    substrate dial FAILED target=\(TransportDebugLog.hex8(addr.id().toBytes()), privacy: .public) \
                    error=\(String(describing: error), privacy: .public) \
                    elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public)
                    """)
            }
            throw error
        }
        let peer = IrohPeerConnection(connection: connection, role: .dialer)
        await peer.start()
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                substrate dial connected conn=\(TransportDebugLog.id(peer), privacy: .public) \
                remote=\(TransportDebugLog.hex8(connection.remoteId().toBytes()), privacy: .public) \
                elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public)
                """)
        }
        return peer
    }

    /// Pull and complete the next incoming connection. Returns nil once the
    /// endpoint is closed.
    public static func acceptOne(endpoint: Endpoint) async throws -> IrohPeerConnection? {
        guard let incoming = await endpoint.acceptNext() else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice("substrate acceptOne: endpoint closed (nil incoming)")
            }
            return nil
        }
        let acceptStart = ContinuousClock.now
        let connection: Connection
        do {
            let accepting = try await incoming.accept()
            connection = try await accepting.connect()
        } catch {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    substrate acceptOne FAILED error=\(String(describing: error), privacy: .public) \
                    elapsedMs=\(TransportDebugLog.ms(since: acceptStart), privacy: .public)
                    """)
            }
            throw error
        }
        let peer = IrohPeerConnection(connection: connection, role: .acceptor)
        await peer.start()
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                substrate accepted conn=\(TransportDebugLog.id(peer), privacy: .public) \
                remote=\(TransportDebugLog.hex8(connection.remoteId().toBytes()), privacy: .public) \
                elapsedMs=\(TransportDebugLog.ms(since: acceptStart), privacy: .public)
                """)
        }
        return peer
    }
}

/// One live iroh QUIC connection behind the substrate seam.
///
/// Lane protocol: the DIALER opens lanes; each new bidirectional stream's
/// first frame is `lane.open {name}`. The ACCEPTOR's `lane(_:)` waits until
/// the peer opens that name. This mirrors how the host code already consumes
/// lanes (it awaits "ctl" first, then named lanes on demand).
public actor IrohPeerConnection: PeerConnection {
    public enum Role: Sendable {
        case dialer, acceptor
    }

    static let laneOpenType = "lane.open"
    static let rawOpenType = "raw.open"

    private let connection: Connection
    private let role: Role
    private let remoteKey: Data
    private var lanes: [String: IrohLane] = [:]
    private var laneWaiters: [String: [CheckedContinuation<any TransportLane, Never>]] = [:]
    private var acceptLoop: Task<Void, Never>?
    private var rawStreamHandler: (@Sendable (String, RawByteStream) async -> Void)?
    private var pendingRawStreams: [(String, RawByteStream)] = []
    private var closedFlag = false
    private var localTermination: ConnectionTermination?

    public init(connection: Connection, role: Role) {
        self.connection = connection
        self.role = role
        self.remoteKey = connection.remoteId().toBytes()
    }

    /// Must be called once after init (an actor cannot spawn tasks on itself
    /// mid-init); the factory methods on IrohSubstrate do this. Both roles
    /// run the inbound accept loop: the acceptor for peer-opened lanes, the
    /// dialer for host-opened streams (server events over the graduation
    /// bridge). A dialer that never receives one just parks on acceptBi.
    public func start() {
        guard acceptLoop == nil else { return }
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) start \
                role=\(String(describing: self.role), privacy: .public) \
                remote=\(TransportDebugLog.hex8(self.remoteKey), privacy: .public)
                """)
        }
        acceptLoop = Task { await self.runAcceptLoop() }
    }

    /// iroh always authenticates the remote endpoint key during the QUIC
    /// handshake; admission judges grants against THIS (contract 3.5).
    public var authenticatedRemoteKey: Data? { remoteKey }

    public var isClosed: Bool {
        closedFlag || connection.closeReason() != nil
    }

    /// Graduation bridge: registers the single owner of inbound raw
    /// application streams. Streams that arrived before registration are
    /// delivered immediately, in arrival order.
    public func onRawStream(
        _ handler: @escaping @Sendable (String, RawByteStream) async -> Void
    ) {
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) raw-stream handler \
                registered pendingFlushed=\(self.pendingRawStreams.count, privacy: .public)
                """)
        }
        rawStreamHandler = handler
        for (preamble, stream) in pendingRawStreams {
            Task { await handler(preamble, stream) }
        }
        pendingRawStreams.removeAll()
    }

    /// Graduation bridge: opens one raw application stream. One handshake
    /// frame carries the preamble; every byte after it is unframed and owned
    /// by the caller (identical wire shape to the legacy transport's lanes).
    public func openRawStream(preamble: String) async throws -> RawByteStream {
        guard !closedFlag else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) openRawStream REFUSED \
                    (connection closed) preamble=\(preamble, privacy: .public)
                    """)
            }
            throw TransportError.pipeClosed
        }
        do {
            let stream = try await connection.openBi()
            let channel = IrohLaneChannel(send: stream.send(), recv: stream.recv())
            try await channel.sendFrame(
                Frame(type: Self.rawOpenType, payload: ["preamble": .string(preamble)]))
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) raw stream opened \
                    preamble=\(preamble, privacy: .public)
                    """)
            }
            return RawByteStream(send: stream.send(), recv: stream.recv(), buffered: Data())
        } catch {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) openRawStream FAILED \
                    preamble=\(preamble, privacy: .public) \
                    error=\(String(describing: error), privacy: .public)
                    """)
            }
            throw error
        }
    }

    public func lane(_ name: String) async -> any TransportLane {
        if let existing = lanes[name] { return existing }
        if closedFlag {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) lane \
                    name=\(name, privacy: .public) -> dead lane (connection closed)
                    """)
            }
            return DeadLane(name: name)
        }
        switch role {
        case .dialer:
            do {
                let stream = try await connection.openBi()
                // Re-check after the suspension: a concurrent caller may have
                // opened the same lane while we awaited. The loser must CLOSE
                // the stream it already opened — dropping the handle leaks a
                // live QUIC stream (and its flow-control credit) for the
                // connection's whole lifetime.
                if let existing = lanes[name] {
                    try? await stream.send().finish()
                    try? await stream.recv().stop(errorCode: 0)
                    return existing
                }
                let channel = IrohLaneChannel(send: stream.send(), recv: stream.recv())
                try await channel.sendFrame(
                    Frame(type: Self.laneOpenType, payload: ["name": .string(name)]))
                let lane = IrohLane(name: name, channel: channel)
                lanes[name] = lane
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        conn \(TransportDebugLog.id(self), privacy: .public) lane opened \
                        (dialer) name=\(name, privacy: .public)
                        """)
                }
                return lane
            } catch {
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.error(
                        """
                        conn \(TransportDebugLog.id(self), privacy: .public) lane open FAILED \
                        (dialer) name=\(name, privacy: .public) \
                        error=\(String(describing: error), privacy: .public) -> dead lane
                        """)
                }
                return DeadLane(name: name)
            }
        case .acceptor:
            return await withCheckedContinuation { continuation in
                if let existing = lanes[name] {
                    continuation.resume(returning: existing)
                } else if closedFlag {
                    if TransportDebugLog.enabled {
                        TransportDebugLog.core.notice(
                            """
                            conn \(TransportDebugLog.id(self), privacy: .public) lane \
                            name=\(name, privacy: .public) -> dead lane (closed while waiting)
                            """)
                    }
                    continuation.resume(returning: DeadLane(name: name))
                } else {
                    if TransportDebugLog.enabled {
                        TransportDebugLog.core.notice(
                            """
                            conn \(TransportDebugLog.id(self), privacy: .public) lane wait \
                            (acceptor) name=\(name, privacy: .public) \
                            waiters=\((self.laneWaiters[name]?.count ?? 0) + 1, privacy: .public)
                            """)
                    }
                    laneWaiters[name, default: []].append(continuation)
                }
            }
        }
    }

    /// No sleeps, no drains (Aziz redline 08-19: we can't depend on time).
    /// The reason rides in the QUIC CONNECTION_CLOSE itself, which the
    /// protocol delivers and retransmits during shutdown; stream frames that
    /// lose the race are irrelevant because termination() carries the cause.
    public func closeAll(reason: ConnectionTermination?) async {
        guard !closedFlag else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) closeAll ignored \
                    (already closed) reason=\(reason?.code ?? "nil", privacy: .public)
                    """)
            }
            return
        }
        closedFlag = true
        localTermination = reason
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) closeAll initiator=local \
                reason=\(reason?.code ?? "nil", privacy: .public) \
                role=\(String(describing: self.role), privacy: .public) \
                remote=\(TransportDebugLog.hex8(self.remoteKey), privacy: .public) \
                openLanes=\(self.lanes.count, privacy: .public) \
                laneWaiters=\(self.laneWaiters.values.reduce(0) { $0 + $1.count }, privacy: .public)
                """)
        }
        acceptLoop?.cancel()
        for lane in lanes.values {
            await lane.finishSend()
        }
        try? connection.close(
            errorCode: reason == nil ? 0 : 1,
            reason: Data((reason?.code ?? "closed").utf8))
        resumeAllWaitersClosed()
    }

    /// The known code vocabulary, longest-first so "grant-expired" wins over
    /// its substring "expired" when parsing the rendered close cause.
    private static let knownTerminationCodes: [String] = {
        let denials = DenialCode.allCases.map(\.rawValue)
        let closes = [
            CloseReason.grantExpired.code, CloseReason.superseded.code,
            CloseReason.modeSwitched.code, CloseReason.userRequested.code,
            CloseReason.explicitRedial.code, CloseReason.admissionDenied.code,
            CloseReason.faultInjected.code,
        ]
        return (denials + closes).sorted { $0.count > $1.count }
    }()

    /// Await only after observing a lane EOF: resolves once the connection's
    /// close cause is known, and parses our reason bytes back out of it.
    public func termination() async -> ConnectionTermination? {
        if let local = localTermination { return local }
        let rendered: String
        if let reason = connection.closeReason() {
            rendered = reason
        } else if closedFlag {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) termination: local close \
                    with no reason recorded -> nil
                    """)
            }
            return nil
        } else {
            rendered = await connection.closed()
        }
        for code in Self.knownTerminationCodes where rendered.contains(code) {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) termination parsed \
                    code=\(code, privacy: .public) \
                    rendered=\(rendered, privacy: .public)
                    """)
            }
            return ConnectionTermination(code: code)
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) termination UNPARSED \
                rendered=\(rendered, privacy: .public) -> nil
                """)
        }
        return nil
    }

    private func runAcceptLoop() async {
        while true {
            do {
                let stream = try await connection.acceptBi()
                let channel = IrohLaneChannel(send: stream.send(), recv: stream.recv())
                guard let open = await channel.receiveFrame() else {
                    if TransportDebugLog.enabled {
                        TransportDebugLog.core.notice(
                            """
                            conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                            inbound stream EOF before open frame; skipped
                            """)
                    }
                    continue
                }
                // Raw application streams (graduation bridge): after the one
                // handshake frame the stream is unframed bytes, handed whole
                // to the registered owner. Decoder leftovers are re-injected
                // so no early raw bytes are lost to frame parsing.
                if open.type == Self.rawOpenType {
                    let preamble = open.payload["preamble"]?.stringValue ?? ""
                    let raw = RawByteStream(
                        send: stream.send(), recv: stream.recv(),
                        buffered: await channel.drainBufferedBytes())
                    if TransportDebugLog.enabled {
                        TransportDebugLog.core.notice(
                            """
                            conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                            inbound raw stream preamble=\(preamble, privacy: .public) \
                            delivery=\(self.rawStreamHandler != nil ? "handler" : "pending", privacy: .public) \
                            remainderBytes=\(raw.handshakeRemainder.count, privacy: .public)
                            """)
                    }
                    if let handler = rawStreamHandler {
                        Task { await handler(preamble, raw) }
                    } else {
                        pendingRawStreams.append((preamble, raw))
                    }
                    continue
                }
                guard open.type == Self.laneOpenType,
                    let name = open.payload["name"]?.stringValue
                else {
                    if TransportDebugLog.enabled {
                        TransportDebugLog.core.error(
                            """
                            conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                            inbound stream with unexpected open frame \
                            type=\(open.type, privacy: .public); skipped
                            """)
                    }
                    continue
                }
                let lane = IrohLane(name: name, channel: channel)
                lanes[name] = lane
                let resumed = laneWaiters.removeValue(forKey: name) ?? []
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                        inbound lane name=\(name, privacy: .public) \
                        waitersResumed=\(resumed.count, privacy: .public)
                        """)
                }
                for waiter in resumed {
                    waiter.resume(returning: lane)
                }
            } catch {
                // Connection died (or closed): every waiter gets a dead lane
                // that EOFs immediately; in-flight lane bytes die with the
                // session (contract 5.4).
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        conn \(TransportDebugLog.id(self), privacy: .public) accept-loop exit \
                        cause=\(String(describing: error), privacy: .public) \
                        remote=\(TransportDebugLog.hex8(self.remoteKey), privacy: .public)
                        """)
                }
                closedFlag = true
                resumeAllWaitersClosed()
                return
            }
        }
    }

    private func resumeAllWaitersClosed() {
        if TransportDebugLog.enabled, !laneWaiters.isEmpty {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) resuming lane waiters as \
                dead lanes lanes=\(self.laneWaiters.keys.joined(separator: ","), privacy: .public) \
                count=\(self.laneWaiters.values.reduce(0) { $0 + $1.count }, privacy: .public)
                """)
        }
        for (name, waiters) in laneWaiters {
            for waiter in waiters {
                waiter.resume(returning: DeadLane(name: name))
            }
        }
        laneWaiters.removeAll()
    }
}

/// One lane on one QUIC stream. Single-consumer, like every lane (see
/// LaneFrames); the channel actor serializes writers so concurrent sends
/// cannot interleave bytes mid-frame.
public final class IrohLane: TransportLane {
    public let name: String
    private let channel: IrohLaneChannel

    init(name: String, channel: IrohLaneChannel) {
        self.name = name
        self.channel = channel
    }

    public func send(_ frame: Frame) async throws {
        try await channel.sendFrame(frame)
    }

    public func receive() async -> Frame? {
        await channel.receiveFrame()
    }

    /// QUIC flow control provides the survivable per-lane backpressure (5.3)
    /// at the transport level; per-stall counting arrives with endpoint
    /// metrics in the lab (endpoint.stats()), not here.
    public var backpressureStalls: Int { 0 }

    func finishSend() async {
        await channel.finish()
    }
}

/// Serializes stream I/O and reassembles frames from arbitrary QUIC reads.
actor IrohLaneChannel {
    private let sendStream: SendStream
    private let recvStream: RecvStream
    private var decoder = FrameDecoder()
    private var pending: [Frame] = []
    private var eof = false
    private let encoder = FrameEncoder()

    init(send: SendStream, recv: RecvStream) {
        self.sendStream = send
        self.recvStream = recv
    }

    func sendFrame(_ frame: Frame) async throws {
        let data = try encoder.encode(frame)
        do {
            try await sendStream.writeAll(buf: data)
        } catch {
            throw TransportError.pipeClosed
        }
    }

    func receiveFrame() async -> Frame? {
        while pending.isEmpty && !eof {
            do {
                let data = try await recvStream.read(sizeLimit: 1 << 16)
                if data.isEmpty {
                    eof = true
                    break
                }
                pending.append(contentsOf: try decoder.feed(data))
            } catch {
                eof = true
            }
        }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    func finish() async {
        try? await sendStream.finish()
    }

    /// Graduation bridge: bytes the frame decoder read past the handshake
    /// frame. Raw handoff must re-inject them ahead of the stream reads.
    func drainBufferedBytes() -> Data {
        var out = Data()
        for frame in pending {
            // A raw peer never sends more frames after raw.open; anything
            // decoded here IS raw payload that happened to parse-attempt.
            if let data = try? FrameEncoder().encode(frame) { out.append(data) }
        }
        pending.removeAll()
        out.append(decoder.drainRemainder())
        return out
    }
}

/// One raw application stream from the graduation bridge: unframed QUIC
/// bytes with the legacy transport's exact wire behavior (bounded reads,
/// backpressured writes, half-close both ways).
public struct RawByteStream: Sendable {
    let send: SendStream
    let recv: RecvStream
    let buffered: Data

    /// Reads at most `maximumByteCount`; nil on clean peer finish. The
    /// handshake leftover (if any) is served before live stream bytes.
    public func read(maximumByteCount: Int, consumedBuffer: inout Data) async throws -> Data? {
        if !consumedBuffer.isEmpty {
            let chunk = consumedBuffer.prefix(maximumByteCount)
            consumedBuffer.removeFirst(chunk.count)
            return Data(chunk)
        }
        let data = try await recv.read(sizeLimit: UInt32(clamping: maximumByteCount))
        return data.isEmpty ? nil : data
    }

    /// Bytes the handshake decoder read past the `raw.open` frame. A consumer
    /// managing its own read buffer seeds it with this before live reads.
    public var handshakeRemainder: Data { buffered }

    public func write(_ data: Data) async throws {
        try await send.writeAll(buf: data)
    }

    /// Relative QUIC scheduling priority of the send half.
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

/// What lane() returns on a dead connection: immediate EOF, fail-fast sends
/// (contract 7.2). Never a hang.
struct DeadLane: TransportLane {
    let name: String

    func send(_ frame: Frame) async throws {
        throw TransportError.pipeClosed
    }

    func receive() async -> Frame? { nil }

    var backpressureStalls: Int { 0 }
}
