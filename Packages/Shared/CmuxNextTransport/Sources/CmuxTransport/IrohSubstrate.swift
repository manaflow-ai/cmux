import Foundation
public import IrohLib

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
    #if compiler(>=6.2)
    @concurrent
    #endif
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
    #if compiler(>=6.2)
    @concurrent
    #endif
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

    #if compiler(>=6.2)
    @concurrent
    #endif
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
            // Keep the cancellable ConnectAttempt handle alive for the whole
            // FFI handshake. A timeout or owner shutdown cancels this task;
            // the attempt's Rust cancellation token then releases a UDP
            // blackhole instead of leaving the caller parked in `connect()`.
            let attempt = try endpoint.beginConnect(addr: addr, alpn: alpn)
            connection = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                let connected = try await attempt.connect()
                try Task.checkCancellation()
                return connected
            }, onCancel: {
                attempt.cancel()
            })
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
    #if compiler(>=6.2)
    @concurrent
    #endif
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
    /// Genuine handshake deadline; injected for deterministic tests and to
    /// ensure a peer cannot park the accept loop forever before sending the
    /// first lane frame.
    private let handshakeSleep: @Sendable (Duration) async throws -> Void
    private var lanes: [String: IrohLane] = [:]
    private var laneWaiters: [String: [(id: UInt64, continuation: CheckedContinuation<any TransportLane, Never>)]] = [:]
    private var laneWaiterTasks: [UInt64: Task<Void, Never>] = [:]
    private var laneWaiterCounter: UInt64 = 0
    private var acceptLoop: Task<Void, Never>?
    /// One bounded worker per accepted bidirectional stream. The accept loop
    /// itself never waits for a peer's `lane.open`/`raw.open` handshake.
    private var inboundStreamTasks: [UInt64: Task<Void, Never>] = [:]
    private var inboundStreamCounter: UInt64 = 0
    private var rawStreamHandler: (@Sendable (String, RawByteStream) async -> Void)?
    private var pendingRawStreams: [(String, RawByteStream)] = []
    /// A single FIFO delivery task preserves the arrival order promised by
    /// `onRawStream`; one task per stream could be scheduled out of order.
    private var rawDeliveryQueue: [(String, RawByteStream)] = []
    private var rawDeliveryHead = 0
    private var rawDeliveryTask: Task<Void, Never>?
    private var closedFlag = false
    private var localTermination: ConnectionTermination?

    private static let maxConcurrentInboundStreams = 64
    private static let maxLaneCount = 128
    private static let inboundOpenDeadline: Duration = .seconds(10)
    private static let laneWaitDeadline: Duration = .seconds(10)

    public init(
        connection: Connection,
        role: Role,
        handshakeSleep: @escaping @Sendable (Duration) async throws -> Void = { delay in
            try await ContinuousClock().sleep(for: delay)
        }
    ) {
        self.connection = connection
        self.role = role
        self.remoteKey = connection.remoteId().toBytes()
        self.handshakeSleep = handshakeSleep
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
    ) async {
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) raw-stream handler \
                registered pendingFlushed=\(self.pendingRawStreams.count, privacy: .public)
                """)
        }
        rawStreamHandler = handler
        rawDeliveryQueue.append(contentsOf: pendingRawStreams)
        pendingRawStreams.removeAll()
        startRawDeliveryIfNeeded()
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
            guard lanes.count < Self.maxLaneCount else {
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.error(
                        "conn \(TransportDebugLog.id(self), privacy: .public) lane limit reached (\(Self.maxLaneCount, privacy: .public)); refusing name=\(name, privacy: .public)")
                }
                return DeadLane(name: name)
            }
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
                let channel = IrohLaneChannel(
                    send: stream.send(), recv: stream.recv(),
                    onProtocolError: { [weak self] in
                        await self?.protocolViolation()
                    })
                try await channel.sendFrame(
                    Frame(type: Self.laneOpenType, payload: ["name": .string(name)]))
                let lane = makeLane(name: name, channel: channel)
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
            laneWaiterCounter &+= 1
            let waiterID = laneWaiterCounter
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
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
                        laneWaiters[name, default: []].append(
                            (id: waiterID, continuation: continuation))
                        let sleep = handshakeSleep
                        laneWaiterTasks[waiterID] = Task { [weak self] in
                            do {
                                try await sleep(Self.laneWaitDeadline)
                            } catch {
                                return
                            }
                            guard let self else { return }
                            await self.expireLaneWaiter(name: name, id: waiterID)
                        }
                    }
                }
            }, onCancel: {
                Task { [weak self] in
                    await self?.cancelLaneWaiter(name: name, id: waiterID)
                }
            })
        }
    }

    /// Resolves one acceptor waiter as a dead lane after the bounded deadline.
    private func expireLaneWaiter(name: String, id: UInt64) {
        guard var waiters = laneWaiters[name],
            let index = waiters.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            laneWaiters.removeValue(forKey: name)
        } else {
            laneWaiters[name] = waiters
        }
        laneWaiterTasks.removeValue(forKey: id)?.cancel()
        waiter.continuation.resume(returning: DeadLane(name: name))
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                "conn \(TransportDebugLog.id(self), privacy: .public) lane wait expired name=\(name, privacy: .public)")
        }
    }

    /// Removes a cancelled waiter without resuming it twice.
    private func cancelLaneWaiter(name: String, id: UInt64) {
        guard var waiters = laneWaiters[name],
            let index = waiters.firstIndex(where: { $0.id == id })
        else {
            laneWaiterTasks.removeValue(forKey: id)?.cancel()
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            laneWaiters.removeValue(forKey: name)
        } else {
            laneWaiters[name] = waiters
        }
        laneWaiterTasks.removeValue(forKey: id)?.cancel()
        waiter.continuation.resume(returning: DeadLane(name: name))
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
        for task in inboundStreamTasks.values { task.cancel() }
        inboundStreamTasks.removeAll()
        rawDeliveryTask?.cancel()
        rawDeliveryTask = nil
        rawDeliveryQueue.removeAll()
        rawDeliveryHead = 0
        pendingRawStreams.removeAll()
        for task in laneWaiterTasks.values { task.cancel() }
        laneWaiterTasks.removeAll()
        let openLanes = Array(lanes.values)
        lanes.removeAll()
        for lane in openLanes {
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
        for code in Self.knownTerminationCodes where Self.renderedReasonContains(rendered, code: code) {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) termination parsed \
                    code=\(code, privacy: .public) \
                    rendered=\(rendered, privacy: .public)
                    """)
            }
            // The matcher above accepts only reason-shaped boundaries, so the
            // recovered code is the structured lifecycle value exposed to the
            // reconnect owner; unrelated diagnostic substrings are ignored.
            return ConnectionTermination(code: code, authority: .authoritative)
        }
        // An unrecognized peer application close is intentionally surfaced as
        // an ambiguity marker. Reconnect policy must not redial a session that
        // may have been superseded merely because a future FFI version changed
        // the human-readable reason format. Transport timeout/reset diagnostics
        // do not match this predicate and retain automatic recovery.
        if Self.renderedPeerApplicationClose(rendered) {
            return ConnectionTermination(code: "connection-lost", authority: .ambiguous)
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

    /// Matches only reason-shaped renderings, never an arbitrary substring of
    /// a transport diagnostic (for example `not-expired`). Local closes use
    /// ``localTermination`` above; this parser is solely a conservative bridge
    /// for remote FFI strings that have no structured reason accessor.
    private static func renderedReasonContains(_ rendered: String, code: String) -> Bool {
        let value = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == code || value.hasSuffix(" \(code)") || value.hasSuffix(":\(code)") {
            return true
        }
        // Current iroh-ffi renders an application close as
        // `closed by peer: <reason> (code <n>)`; future versions may quote the
        // reason or add a prefix. Extract only the token immediately following
        // a reason-labelled boundary, never an arbitrary diagnostic substring.
        for marker in [
            "closed by peer: ", "aborted by peer: ", "reason=", "reason: ",
            "reason \"", "reason='"
        ] {
            guard let range = value.range(of: marker, options: .backwards) else { continue }
            let tail = value[range.upperBound...]
            let token = tail.split(whereSeparator: {
                $0 == " " || $0 == "(" || $0 == ")" || $0 == ","
                    || $0 == "\"" || $0 == "'" || $0 == ":"
            }).first.map(String.init)
            if token == code { return true }
        }
        return false
    }

    /// Returns true for a peer application-close diagnostic without trusting
    /// any reason text inside it. This is only an ambiguity fence for retry
    /// policy; it never claims a lifecycle code.
    private static func renderedPeerApplicationClose(_ rendered: String) -> Bool {
        let value = rendered.lowercased()
        return value.hasPrefix("closed by peer")
            || value.hasPrefix("aborted by peer")
            || value.contains("connectionclosed(")
            || value.contains("applicationclosed(")
            || (value.contains("peer") && value.contains("closed")
                && (value.contains("code") || value.contains("reason")))
    }

    /// Creates a lane whose end callback returns ownership to this
    /// connection, allowing completed streams to leave the bounded registry.
    private func makeLane(name: String, channel: IrohLaneChannel) -> IrohLane {
        let token = UUID()
        return IrohLane(name: name, channel: channel, token: token) { [weak self] in
            await self?.laneEnded(name: name, token: token)
        }
    }

    /// Removes a completed lane only when the callback belongs to the stream
    /// currently registered under that name; a newer stream with the same name
    /// must not be removed by a stale EOF callback.
    private func laneEnded(name: String, token: UUID) {
        guard lanes[name]?.token == token else { return }
        lanes.removeValue(forKey: name)
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                "conn \(TransportDebugLog.id(self), privacy: .public) lane released name=\(name, privacy: .public) remaining=\(self.lanes.count, privacy: .public)")
        }
    }

    private func runAcceptLoop() async {
        while true {
            do {
                let stream = try await connection.acceptBi()
                guard !Task.isCancelled, !closedFlag else {
                    await closeUnadoptedStream(stream)
                    return
                }
                guard inboundStreamTasks.count < Self.maxConcurrentInboundStreams else {
                    if TransportDebugLog.enabled {
                        TransportDebugLog.core.error(
                            """
                            conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                            inbound stream limit reached (\(Self.maxConcurrentInboundStreams, privacy: .public)); rejecting
                            """)
                    }
                    await closeUnadoptedStream(stream)
                    continue
                }
                inboundStreamCounter &+= 1
                let taskID = inboundStreamCounter
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.processInboundStream(stream, taskID: taskID)
                }
                inboundStreamTasks[taskID] = task
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

    /// Handles one stream independently of the accept loop. A peer that opens
    /// a stream and never sends its preamble therefore consumes only one
    /// bounded worker and cannot block later control/application lanes.
    private func processInboundStream(_ stream: BiStream, taskID: UInt64) async {
        defer { inboundStreamTasks.removeValue(forKey: taskID) }
        let channel = IrohLaneChannel(
            send: stream.send(), recv: stream.recv(),
            onProtocolError: { [weak self] in
                await self?.protocolViolation()
            })
        guard let open = await receiveOpenFrameWithDeadline(channel: channel) else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                    inbound stream EOF/deadline before open frame; skipped
                    """)
            }
            await closeUnadoptedStream(stream)
            return
        }

        // Raw application streams (graduation bridge): after the one
        // handshake frame the stream is unframed bytes, handed whole to the
        // registered owner. `receiveOpenFrame` intentionally leaves all
        // coalesced bytes in the decoder remainder.
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
            if rawStreamHandler != nil {
                guard rawDeliveryQueue.count - rawDeliveryHead < Self.maxConcurrentInboundStreams else {
                    await raw.resetSend(errorCode: 1)
                    await raw.stopReceiving(errorCode: 1)
                    return
                }
                rawDeliveryQueue.append((preamble, raw))
                // Delivery is serialized through one FIFO task so the
                // handler observes streams in substrate arrival order.
                startRawDeliveryIfNeeded()
            } else {
                guard pendingRawStreams.count < Self.maxConcurrentInboundStreams else {
                    await raw.resetSend(errorCode: 1)
                    await raw.stopReceiving(errorCode: 1)
                    return
                }
                pendingRawStreams.append((preamble, raw))
            }
            return
        }

        guard open.type == Self.laneOpenType,
            let name = open.payload["name"]?.stringValue,
            !name.isEmpty,
            name.utf8.count <= 256
        else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                    inbound stream with unexpected open frame type=\(open.type, privacy: .public); closing
                    """)
            }
            if !open.type.hasPrefix(FrameTypePolicy.optionalPrefix) {
                await closeAll(
                    reason: ConnectionTermination(code: DenialCode.protocolMismatch.rawValue))
            }
            await closeUnadoptedStream(stream)
            return
        }
        guard lanes.count < Self.maxLaneCount else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                    lane limit reached (\(Self.maxLaneCount, privacy: .public)); rejecting name=\(name, privacy: .public)
                    """)
            }
            await closeUnadoptedStream(stream)
            return
        }
        guard lanes[name] == nil else {
            // Keep the first stream as the lane's single source of truth;
            // accepting a duplicate would orphan the original consumer and
            // retain another live QUIC stream indefinitely.
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                    duplicate inbound lane name=\(name, privacy: .public); rejecting
                    """)
            }
            await closeUnadoptedStream(stream)
            return
        }

        let lane = makeLane(
            name: name,
            channel: channel)
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
            laneWaiterTasks.removeValue(forKey: waiter.id)?.cancel()
            waiter.continuation.resume(returning: lane)
        }
    }

    /// Races the first-frame read against a genuine, cancellable deadline.
    /// On timeout, stopping the receive half is what wakes the FFI read; task
    /// cancellation alone is not sufficient for all iroh-ffi versions.
    private func receiveOpenFrameWithDeadline(channel: IrohLaneChannel) async -> Frame? {
        let sleep = handshakeSleep
        return await withTaskGroup(of: Frame?.self) { group in
            group.addTask { await channel.receiveOpenFrame() }
            group.addTask {
                do {
                    try await sleep(Self.inboundOpenDeadline)
                } catch {
                    return nil
                }
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            if result == nil {
                await channel.abortReceive()
            }
            await group.waitForAll()
            return result
        }
    }

    private func closeUnadoptedStream(_ stream: BiStream) async {
        try? await stream.send().finish()
        try? await stream.recv().stop(errorCode: 1)
    }

    /// Closes the whole session when a framed lane cannot be decoded. A plain
    /// EOF would otherwise look like an ordinary transport loss to the
    /// reconnect owner and hide a protocol/version violation.
    private func protocolViolation() async {
        guard !closedFlag else { return }
        await closeAll(
            reason: ConnectionTermination(code: DenialCode.protocolMismatch.rawValue))
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
                laneWaiterTasks.removeValue(forKey: waiter.id)?.cancel()
                waiter.continuation.resume(returning: DeadLane(name: name))
            }
        }
        laneWaiters.removeAll()
        laneWaiterTasks.removeAll()
    }

    /// Starts the one FIFO raw-stream delivery worker, if a handler is ready.
    private func startRawDeliveryIfNeeded() {
        guard rawDeliveryTask == nil, let handler = rawStreamHandler else { return }
        rawDeliveryTask = Task { [weak self] in
            while let self, let item = await self.nextRawDelivery() {
                await handler(item.0, item.1)
            }
            await self?.rawDeliveryFinished()
        }
    }

    /// Pops the next queued raw stream for the delivery worker.
    private func nextRawDelivery() -> (String, RawByteStream)? {
        guard rawDeliveryHead < rawDeliveryQueue.count else {
            rawDeliveryQueue.removeAll(keepingCapacity: true)
            rawDeliveryHead = 0
            return nil
        }
        let item = rawDeliveryQueue[rawDeliveryHead]
        rawDeliveryHead += 1
        // Compact only after a meaningful prefix has been consumed; this keeps
        // dequeue cost amortized O(1) without retaining old stream handles.
        if rawDeliveryHead >= 32, rawDeliveryHead * 2 >= rawDeliveryQueue.count {
            rawDeliveryQueue.removeSubrange(0..<rawDeliveryHead)
            rawDeliveryHead = 0
        }
        return item
    }

    /// Clears the completed worker handle; a later arrival can start a new one.
    private func rawDeliveryFinished() {
        rawDeliveryTask = nil
        if rawDeliveryHead < rawDeliveryQueue.count { startRawDeliveryIfNeeded() }
    }
}

/// One lane on one QUIC stream. Single-consumer, like every lane (see
/// LaneFrames); the channel actor serializes writers so concurrent sends
/// cannot interleave bytes mid-frame.
public actor IrohLane: TransportLane {
    public nonisolated let name: String
    private let channel: IrohLaneChannel
    /// Stable token used by the owning connection to remove this lane only
    /// if the callback belongs to the currently registered stream.
    nonisolated let token: UUID
    private let onEnd: (@Sendable () async -> Void)?
    private var endNotified = false

    init(
        name: String,
        channel: IrohLaneChannel,
        token: UUID = UUID(),
        onEnd: (@Sendable () async -> Void)? = nil
    ) {
        self.name = name
        self.channel = channel
        self.token = token
        self.onEnd = onEnd
    }

    public func send(_ frame: Frame) async throws {
        try await channel.sendFrame(frame)
    }

    public func receive() async -> Frame? {
        let frame = await channel.receiveFrame()
        if frame == nil, !endNotified {
            endNotified = true
            await onEnd?()
        }
        return frame
    }

    /// Number of short writes observed while QUIC flow control applied
    /// backpressure to this lane.
    public var backpressureStalls: Int {
        get async { await channel.backpressureStalls }
    }

    func finishSend() async {
        await channel.finish()
    }
}

/// Serializes stream I/O and reassembles frames from arbitrary QUIC reads.
actor IrohLaneChannel {
    private let sendStream: SendStream
    private let recvStream: RecvStream
    private var decoder = FrameDecoder(captureEncodedFrames: true)
    private var pending = FIFOQueue<(frame: Frame, encoded: Data)>()
    private var eof = false
    private var protocolErrorNotified = false
    private var backpressureStallCount = 0
    private let encoder = FrameEncoder()
    private let frameTypePolicy = FrameTypePolicy()
    private let onProtocolError: (@Sendable () async -> Void)?

    init(
        send: SendStream,
        recv: RecvStream,
        onProtocolError: (@Sendable () async -> Void)? = nil
    ) {
        self.sendStream = send
        self.recvStream = recv
        self.onProtocolError = onProtocolError
    }

    func sendFrame(_ frame: Frame) async throws {
        let data = try encoder.encode(frame)
        do {
            var offset = 0
            while offset < data.count {
                let remaining = data.dropFirst(offset)
                let written = try await sendStream.write(buf: Data(remaining))
                guard written > 0, written <= UInt64(remaining.count) else {
                    throw TransportError.pipeClosed
                }
                if written < UInt64(remaining.count) {
                    // A short write is the FFI-visible evidence that QUIC
                    // flow control required another turn; count it for the
                    // lane diagnostics without guessing from wall time.
                    backpressureStallCount += 1
                }
                offset += Int(written)
            }
        } catch {
            throw TransportError.pipeClosed
        }
    }

    /// Number of short writes observed while QUIC flow control was applying
    /// backpressure to this lane.
    var backpressureStalls: Int { backpressureStallCount }

    func receiveFrame() async -> Frame? {
        while pending.isEmpty && !eof {
            do {
                // First decode any complete frames left by the opening-frame
                // handoff. A coalesced lane.open + data frame must be
                // available immediately; waiting for another network read
                // here would otherwise stall a perfectly live lane.
                var frames = try decoder.feed(Data())
                let encoded = decoder.drainEncodedFrames()
                // The decoder emits one encoded byte sequence per frame. Keep
                // the pairing so a framed-to-raw handoff can replay exact wire
                // bytes, including the original JSON key order and escaping.
                guard frames.count == encoded.count else {
                    eof = true
                    break
                }
                guard appendDecoded(frames, encoded: encoded) else { break }
                if !pending.isEmpty { break }

                let data = try await recvStream.read(sizeLimit: 1 << 16)
                if data.isEmpty {
                    eof = true
                    break
                }
                frames = try decoder.feed(data)
                let encodedAfterRead = decoder.drainEncodedFrames()
                guard frames.count == encodedAfterRead.count else {
                    eof = true
                    break
                }
                guard appendDecoded(frames, encoded: encodedAfterRead) else { break }
            } catch let error as FrameCodecError {
                eof = true
                notifyProtocolError(error)
            } catch {
                eof = true
            }
        }
        return pending.popFirst()?.frame
    }

    /// Reads exactly one opening frame and leaves all coalesced bytes in the
    /// decoder remainder for a later raw-stream consumer. Unlike
    /// ``receiveFrame()``, this never attempts to parse bytes after the
    /// opening frame as JSON.
    func receiveOpenFrame() async -> Frame? {
        while !eof {
            do {
                let data = try await recvStream.read(sizeLimit: 1 << 16)
                if data.isEmpty {
                    eof = true
                    break
                }
                if let frame = try decoder.feedFirst(data) {
                    // The opening frame is consumed by the caller; do not
                    // leave its captured wire bytes in the handoff queue.
                    _ = decoder.drainEncodedFrames()
                    return frame
                }
            } catch let error as FrameCodecError {
                eof = true
                notifyProtocolError(error)
                break
            } catch {
                eof = true
                break
            }
        }
        return nil
    }

    /// Wakes a pending receive when a handshake deadline expires.
    func abortReceive() async {
        try? await recvStream.stop(errorCode: 1)
        eof = true
    }

    func finish() async {
        try? await sendStream.finish()
    }

    /// Graduation bridge: bytes the frame decoder read past the handshake
    /// frame. Raw handoff must re-inject them ahead of the stream reads.
    func drainBufferedBytes() -> Data {
        var out = Data()
        while let item = pending.popFirst() {
            // A raw peer never sends more frames after raw.open; anything
            // decoded here IS raw payload that happened to parse-attempt. Use
            // the original bytes, never a freshly encoded approximation.
            out.append(item.encoded)
        }
        out.append(decoder.drainRemainder())
        return out
    }

    private func notifyProtocolError(_ error: FrameCodecError) {
        guard !protocolErrorNotified else { return }
        protocolErrorNotified = true
        _ = error
        // Do not await the parent connection while this channel is servicing
        // the lane read: the parent's close path finishes every lane and would
        // otherwise wait on this actor recursively. The one-shot task is
        // weakly owned by the callback's parent and immediately closes the
        // native connection, which releases this read before lane cleanup.
        let callback = onProtocolError
        Task { await callback?() }
    }

    /// Applies the mandatory/optional frame-type policy at the framed receive
    /// boundary. Consumers never get a mandatory unknown frame to accidentally
    /// treat as an ignorable application message.
    private func appendDecoded(_ frames: [Frame], encoded: [Data]) -> Bool {
        guard frames.count == encoded.count else {
            eof = true
            return false
        }
        for (frame, bytes) in zip(frames, encoded) {
            if frameTypePolicy.classify(frame.type) == .fatalUnknown {
                eof = true
                notifyProtocolError(.unknownMandatoryType(frame.type))
                return false
            }
            pending.append((frame: frame, encoded: bytes))
        }
        return true
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
