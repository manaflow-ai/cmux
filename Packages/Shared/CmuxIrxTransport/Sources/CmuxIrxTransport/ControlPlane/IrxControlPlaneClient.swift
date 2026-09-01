public import Foundation

/// Persisted control-plane sync position: the highest account route revision
/// this device has fully received. Sent as `haveRev` on reconnect so the
/// server can resume with deltas instead of a full snapshot.
struct IrxControlPlaneCursor: Codable, Equatable, Sendable {
    var haveRev: Int?
}

/// The always-on fact channel to the per-account control-plane Durable
/// Object. Never on the dial path: the phone dials from persisted state and
/// this socket delivers corrections (fresh relay passes, home-relay hints,
/// directory changes) the instant they exist, plus the initial snapshot as a
/// burst of revisioned deltas.
///
/// Lifecycle mirrors the credential autopilot: `start()` owns a reconnect
/// loop with capped jittered backoff, `kick()` is the foreground reset (iOS
/// suspension kills the socket silently; that is expected), `stop()` ends it.
public actor IrxControlPlaneClient {
    public struct Configuration: Sendable {
        public var socketURL: URL
        public var endpointIDHex: String
        public var wantPasses: Bool
        public var cacheDirectory: URL
        /// Optional client identification carried on the hello so the server
        /// can seed and version-stamp this device's directory entry.
        public var clientInfo: IrxCtlClientInfo?
        /// The app namespace (`X-Cmux-App-Namespace`) sent on the socket
        /// open. The DO reuses it for upstream discovery, so it must match
        /// the namespace the broker service registers under.
        public var clientNamespace: String?

        public init(
            socketURL: URL,
            endpointIDHex: String,
            wantPasses: Bool,
            cacheDirectory: URL,
            clientInfo: IrxCtlClientInfo? = nil,
            clientNamespace: String? = nil
        ) {
            self.socketURL = socketURL
            self.endpointIDHex = endpointIDHex
            self.wantPasses = wantPasses
            self.cacheDirectory = cacheDirectory
            self.clientInfo = clientInfo
            self.clientNamespace = clientNamespace
        }
    }

    public struct Handlers: Sendable {
        public var onRelayPasses: @Sendable ([IrxRelayCredential]) async -> Bool
        public var onHintUpdate: @Sendable (_ endpointIDHex: String, _ relayURL: String) async -> Bool
        public var onDirectory: @Sendable (CTLDirectoryPayload) async -> Bool
        public var onSnapshotComplete: @Sendable (_ rev: Int) async -> Void
        /// The list-auth overlay of a directory fact (rev + lease stamp +
        /// per-entry authorization). The consumer applies it, then calls
        /// ``IrxControlPlaneClient/acknowledge(rev:)``.
        public var onDirectoryFact: (@Sendable (IrxCtlDirectoryFact) async -> Bool)?
        /// An explicit freshness re-stamp (a `current` frame, or a
        /// `snapshot_complete` carrying `issuedAt`).
        public var onFreshness: (@Sendable (_ rev: Int, _ issuedAt: Date) async -> Void)?

        public init(
            onRelayPasses: @escaping @Sendable ([IrxRelayCredential]) async -> Bool,
            onHintUpdate: @escaping @Sendable (String, String) async -> Bool,
            onDirectory: @escaping @Sendable (CTLDirectoryPayload) async -> Bool,
            onSnapshotComplete: @escaping @Sendable (Int) async -> Void,
            onDirectoryFact: (@Sendable (IrxCtlDirectoryFact) async -> Bool)? = nil,
            onFreshness: (@Sendable (_ rev: Int, _ issuedAt: Date) async -> Void)? = nil
        ) {
            self.onRelayPasses = onRelayPasses
            self.onHintUpdate = onHintUpdate
            self.onDirectory = onDirectory
            self.onSnapshotComplete = onSnapshotComplete
            self.onDirectoryFact = onDirectoryFact
            self.onFreshness = onFreshness
        }
    }

    private let configuration: Configuration
    /// Stack token pair: the worker's upstream proxy needs BOTH the access
    /// token (Authorization) and the refresh token (x-stack-refresh-token);
    /// the web API's native auth rejects a bearer alone.
    private let tokenPair: @Sendable () async throws -> (access: String, refresh: String)?
    private let journal: IrxJournal
    private let handlers: Handlers
    private let cursorCache: IrxDiskCache<IrxControlPlaneCursor>
    /// JSONDecoder is mutable and therefore stays isolated to this actor.
    /// Reusing the instance avoids rebuilding ISO-8601 formatters for every
    /// heartbeat or directory frame without introducing shared state.
    private let decoder: JSONDecoder
    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    /// Generation of the one control-plane loop. A cancelled URLSession task
    /// may linger inside an awaited receive, so a new kick must invalidate the
    /// old loop before starting its replacement.
    private var loopGeneration: UInt64 = 0
    private var backoff: Duration = .seconds(1)
    /// Highest revision acknowledged on the CURRENT socket; duplicate acks
    /// (a directory frame that also fanned hint updates) collapse here.
    private var lastAckedRev: Int?
    private static let maxBackoff: Duration = .seconds(30)

    /// Frame router probe: read only the discriminator, then decode the
    /// exact generated type. Unknown types are journaled and skipped so a
    /// newer server can add fact kinds without breaking installed clients
    /// (the additive-evolution contract).
    private struct TypeProbe: Decodable {
        let type: String
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = iso.date(from: raw) ?? fractional.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unparseable date: \(raw)"
            ))
        }
        return decoder
    }

    /// The server sends an application heartbeat every 60 seconds. A receive
    /// that outlives that interval is a zombie WebSocket, not a healthy idle
    /// connection, so bound it and let `run()` own reconnect/backoff.
    private static let receiveTimeout: Duration = .seconds(90)

    private struct ReceiveTimeout: Error, Sendable {}

    private func receive(
        from task: URLSessionWebSocketTask
    ) async throws -> URLSessionWebSocketTask.Message {
        do {
            return try await withThrowingTaskGroup(
                of: URLSessionWebSocketTask.Message.self
            ) { group in
                group.addTask { try await task.receive() }
                group.addTask {
                    try await Task.sleep(for: Self.receiveTimeout)
                    throw ReceiveTimeout()
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch is ReceiveTimeout {
            task.cancel(with: .goingAway, reason: nil)
            journal.record("control-plane", "receive-timeout")
            throw IrxConnectionError.closed(nil)
        }
    }

    /// Reconstruct the generated legacy payload from the tolerant overlay.
    /// Older servers omit the lease fields, so `CTLDirectory` cannot decode
    /// them directly. Keeping this bridge means the existing directory
    /// consumer still receives every route and binding while the overlay
    /// consumer applies list-auth defaults independently.
    static func legacyDirectoryPayload(
        from fact: IrxCtlDirectoryFact,
        receivedAt: Date = Date()
    ) -> CTLDirectoryPayload {
        CTLDirectoryPayload(
            bindings: fact.payload.bindings.map { entry in
                Binding(
                    appVersion: entry.appVersion,
                    bindingID: entry.bindingID ?? "",
                    capabilities: entry.capabilities,
                    clientNamespace: entry.clientNamespace ?? "",
                    deviceID: entry.deviceID,
                    endpointID: entry.endpointID,
                    homeRelayURL: entry.homeRelayURL,
                    instanceTag: entry.instanceTag,
                    lastConfirmedAt: entry.lastConfirmedAt,
                    releaseTrack: entry.releaseTrack.flatMap(ReleaseTrack.init(rawValue:)),
                    revoked: entry.revoked ?? false,
                    status: entry.status.flatMap(Status.init(rawValue:)),
                    updatedAt: entry.updatedAt
                )
            },
            grantVerificationKeys: fact.payload.grantVerificationKeys ?? [],
            issuedAt: fact.payload.issuedAt ?? receivedAt,
            minimumSupportedVersion: fact.payload.minimumSupportedVersion.map {
                PurpleMinimumSupportedVersion(ios: $0.ios, mac: $0.mac)
            },
            relayFleet: fact.payload.relayFleet ?? [],
            routeContractVersion: fact.payload.routeContractVersion ?? 1,
            ttlSeconds: fact.payload.ttlSeconds ?? IrxDeviceListSnapshot.defaultTTLSeconds
        )
    }

    public init(
        configuration: Configuration,
        tokenPair: @escaping @Sendable () async throws -> (access: String, refresh: String)?,
        handlers: Handlers,
        journal: IrxJournal
    ) {
        self.configuration = configuration
        self.tokenPair = tokenPair
        self.handlers = handlers
        self.journal = journal
        decoder = Self.makeDecoder()
        cursorCache = IrxDiskCache(
            fileURL: configuration.cacheDirectory
                .appendingPathComponent("control-plane-cursor.json")
        )
    }

    // MARK: - Lifecycle

    public func start() {
        guard loop == nil else { return }
        loopGeneration &+= 1
        let generation = loopGeneration
        loop = Task { await self.run(generation: generation) }
        journal.record("control-plane", "started")
    }

    public func stop() {
        loopGeneration &+= 1
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        journal.record("control-plane", "stopped")
    }

    /// Foreground reset: reconnect NOW with a fresh token instead of waiting
    /// out whatever backoff a background suspension left behind.
    public func kick() {
        loopGeneration &+= 1
        let generation = loopGeneration
        loop?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        backoff = .seconds(1)
        loop = Task { await self.run(generation: generation) }
        journal.record("control-plane", "kicked")
    }

    // MARK: - Connection loop

    private func run(generation: UInt64) async {
        while !Task.isCancelled && generation == loopGeneration {
            do {
                try await connectAndServe(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                journal.record(
                    "control-plane", "socket-ended",
                    ["error": String(describing: error)]
                )
            }
            if Task.isCancelled || generation != loopGeneration { return }
            let jitter = Duration.milliseconds(Int.random(in: 0...500))
            let delay = backoff + jitter
            backoff = min(backoff * 2, Self.maxBackoff)
            journal.record(
                "control-plane", "reconnect-scheduled",
                ["delay": String(describing: delay)]
            )
            try? await Task.sleep(for: delay)
        }
    }

    private func connectAndServe(generation: UInt64) async throws {
        guard let tokens = try await tokenPair() else {
            throw IrxConnectionError.closed(nil)
        }
        guard generation == loopGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
        var request = URLRequest(url: configuration.socketURL)
        request.setValue("Bearer \(tokens.access)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.refresh, forHTTPHeaderField: "x-stack-refresh-token")
        // The DO borrows this connection's identity for its upstream
        // discovery fetches; without the namespace the broker serves the
        // release-scoped view and per-tag isolation hides every dev-tagged
        // binding — including this device's own peers — from the directory.
        if let namespace = configuration.clientNamespace {
            request.setValue(namespace, forHTTPHeaderField: "X-Cmux-App-Namespace")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        lastAckedRev = nil
        task.resume()

        // Hello v2: the generated hello fields plus optional client info
        // (device, platform, version, capabilities); old servers ignore the
        // extra keys.
        let hello = IrxCtlHelloV2(
            endpointID: configuration.endpointIDHex,
            haveRev: cursorCache.load()?.haveRev,
            wantPasses: configuration.wantPasses,
            clientInfo: configuration.clientInfo
        )
        let helloData = try JSONEncoder().encode(hello)
        try await task.send(.string(String(decoding: helloData, as: UTF8.self)))
        journal.record(
            "control-plane", "hello-sent",
            ["have_rev": cursorCache.load()?.haveRev.map(String.init) ?? "-"]
        )

        while !Task.isCancelled && generation == loopGeneration {
            let message = try await receive(from: task)
            guard generation == loopGeneration else { return }
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let raw): data = raw
            @unknown default: continue
            }
            await route(data, generation: generation)
        }
    }

    private func route(_ data: Data, generation: UInt64) async {
        guard generation == loopGeneration, !Task.isCancelled else { return }
        guard let probe = try? decoder.decode(TypeProbe.self, from: data) else {
            journal.record("control-plane", "frame-unparseable")
            return
        }
        do {
            switch probe.type {
            case "ping":
                // Cloudflare Workers' hibernation API does not expose a
                // portable server-side RFC6455 ping, so the DO uses a small
                // application heartbeat. Reply immediately without routing
                // it through the durable fact decoder.
                guard let socket else { return }
                let pong = Data("{\"v\":1,\"type\":\"pong\",\"payload\":{}}".utf8)
                do {
                    try await socket.send(
                        .string(String(decoding: pong, as: UTF8.self)))
                    journal.record("control-plane", "pong-sent")
                } catch {
                    journal.record(
                        "control-plane", "pong-failed",
                        ["error": String(describing: error)]
                    )
                }
            case "pong":
                journal.record("control-plane", "pong-received")
            case "hello_ack":
                let ack = try decoder.decode(CTLHelloACK.self, from: data)
                // List-auth additions (serverCapabilities, minimum version)
                // are advisory; tolerate their absence and journal presence.
                let overlay = try? decoder.decode(IrxCtlHelloAckOverlay.self, from: data)
                journal.record(
                    "control-plane", "hello-ack",
                    [
                        "session": ack.payload.sessionID,
                        "resumed_from": ack.payload.resumedFromRev.map(String.init) ?? "snapshot",
                        "server_capabilities": overlay?.payload?.serverCapabilities?
                            .joined(separator: ",") ?? "-",
                    ]
                )
            case "relay_passes":
                let fact = try decoder.decode(CTLRelayPasses.self, from: data)
                guard fact.payload.endpointID == configuration.endpointIDHex else {
                    journal.record("control-plane", "passes-wrong-endpoint")
                    return
                }
                let credentials = fact.payload.passes.map {
                    IrxRelayCredential(
                        relayURL: $0.relayURL,
                        token: $0.token,
                        expiresAt: $0.expiresAt,
                        refreshAfter: $0.refreshAfter
                    )
                }
                journal.record(
                    "control-plane", "passes-received",
                    ["rev": String(fact.rev), "count": String(credentials.count)]
                )
                if await handlers.onRelayPasses(credentials) {
                    // Relay credentials are a revisioned control-plane fact.
                    // Ack only after the consumer accepted and persisted them.
                    await acknowledge(rev: fact.rev)
                }
            case "hint_update":
                let fact = try decoder.decode(CTLHintUpdate.self, from: data)
                journal.record(
                    "control-plane", "hint-update",
                    [
                        "rev": String(fact.rev),
                        "endpoint": String(fact.payload.endpointID.prefix(12)),
                        "relay": fact.payload.homeRelayURL,
                    ]
                )
                if await handlers.onHintUpdate(
                    fact.payload.endpointID, fact.payload.homeRelayURL)
                {
                    // Hint updates are independently revisioned when delivered
                    // outside a directory snapshot; ack after applying them.
                    await acknowledge(rev: fact.rev)
                }
            case "directory":
                // The tolerant overlay is the PRIMARY decode: every list-auth
                // field is optional there, so directories from both old and
                // new servers parse. The generated strict type (which now
                // REQUIRES the lease stamp) feeds the legacy handler
                // best-effort only.
                let listFact = try decoder.decode(IrxCtlDirectoryFact.self, from: data)
                journal.record(
                    "control-plane", "directory",
                    [
                        "rev": String(listFact.rev),
                        "bindings": String(listFact.payload.bindings.count),
                        "stamped": String(listFact.payload.issuedAt != nil),
                    ]
                )
                var applied = false
                if let fact = try? decoder.decode(CTLDirectory.self, from: data) {
                    applied = await handlers.onDirectory(fact.payload)
                } else {
                    applied = await handlers.onDirectory(
                        Self.legacyDirectoryPayload(from: listFact))
                }
                for binding in listFact.payload.bindings {
                    if let relay = binding.homeRelayURL {
                        applied = await handlers.onHintUpdate(binding.endpointID, relay) && applied
                    }
                }
                if let onDirectoryFact = handlers.onDirectoryFact {
                    applied = await onDirectoryFact(listFact) && applied
                }
                // Directory delivery is itself a revisioned fact. Ack only
                // after every consumer reports durable application.
                if applied { await acknowledge(rev: listFact.rev) }
            case "current":
                // Explicit freshness re-stamp for the device-list lease.
                let stamp = try decoder.decode(IrxCtlFreshnessStamp.self, from: data)
                journal.record(
                    "control-plane", "current",
                    [
                        "rev": String(stamp.rev),
                        "stamped": String(stamp.issuedAt != nil),
                    ]
                )
                if let issuedAt = stamp.issuedAt {
                    await handlers.onFreshness?(stamp.rev, issuedAt)
                }
            case "snapshot_complete":
                let fact = try decoder.decode(CTLSnapshotComplete.self, from: data)
                cursorCache.save(IrxControlPlaneCursor(haveRev: fact.rev))
                backoff = .seconds(1)
                journal.record(
                    "control-plane", "snapshot-complete", ["rev": String(fact.rev)]
                )
                await handlers.onSnapshotComplete(fact.rev)
                // The server may extend snapshot_complete with issuedAt as a
                // lease re-stamp; handle it defensively alongside `current`.
                if let stamp = try? decoder.decode(
                    IrxCtlFreshnessStamp.self, from: data),
                    let issuedAt = stamp.issuedAt
                {
                    await handlers.onFreshness?(stamp.rev, issuedAt)
                }
            case "error":
                let fact = try decoder.decode(CTLError.self, from: data)
                journal.record(
                    "control-plane", "server-error",
                    [
                        "code": fact.payload.code,
                        "retryable": String(fact.payload.retryable),
                    ]
                )
            default:
                journal.record(
                    "control-plane", "frame-ignored", ["type": probe.type]
                )
            }
        } catch {
            journal.record(
                "control-plane", "frame-decode-failed",
                ["type": probe.type, "error": String(describing: error)]
            )
        }
    }

    // MARK: - Acknowledgment

    /// Confirms a directory/hint revision was APPLIED (persisted and swapped
    /// into the live judge), so the server can track fleet convergence.
    /// Idempotent per socket: a revision already acknowledged on this
    /// connection is skipped; the counter resets on reconnect because the
    /// server re-learns position from the hello's `haveRev`.
    public func acknowledge(rev: Int) async {
        guard let socket else { return }
        if let lastAckedRev, rev <= lastAckedRev { return }
        guard let data = try? Self.encodedAck(rev: rev) else { return }
        do {
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            lastAckedRev = rev
            journal.record("control-plane", "acked", ["rev": String(rev)])
        } catch {
            journal.record(
                "control-plane", "ack-failed",
                ["rev": String(rev), "error": String(describing: error)]
            )
        }
    }

    /// The ack frame bytes (generated `CTLACK`, RFC3339 applied stamp),
    /// exposed for wire-shape tests.
    static func encodedAck(rev: Int, appliedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(
            CTLACK(payload: CTLACKPayload(appliedAt: appliedAt), rev: rev, type: .ack, v: 1))
    }

    // MARK: - Publishing (Mac)

    /// Announces this endpoint's home relay to the account's other devices.
    /// Purely the instant-propagation lane: the signed HTTPS registration
    /// remains the authoritative write, and the server confirms by re-fetching
    /// discovery. Best-effort by design; a miss costs nothing (the alarm
    /// re-fetch covers it).
    public func publishHint(homeRelayURL: String) async {
        guard let socket else { return }
        let frame = CTLPublishHint(
            payload: CTLPublishHintPayload(
                endpointID: configuration.endpointIDHex,
                homeRelayURL: homeRelayURL,
                proof: nil
            ),
            type: .publishHint,
            v: 1
        )
        guard let data = try? JSONEncoder().encode(frame) else { return }
        try? await socket.send(.string(String(decoding: data, as: UTF8.self)))
        journal.record(
            "control-plane", "hint-published", ["relay": homeRelayURL]
        )
    }

    /// Requests a socket-delivered mint (server proxies with warm upstream
    /// connections and one retry). The reply arrives as an ordinary
    /// relay_passes fact; the HTTPS autopilot stays as the fallback minter.
    public func requestMint() async {
        guard let socket else { return }
        let frame = CTLMintRequest(
            payload: CTLMintRequestPayload(
                endpointID: configuration.endpointIDHex,
                proof: nil
            ),
            type: .mintRequest,
            v: 1
        )
        guard let data = try? JSONEncoder().encode(frame) else { return }
        try? await socket.send(.string(String(decoding: data, as: UTF8.self)))
        journal.record("control-plane", "mint-requested")
    }
}
