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

        public init(
            socketURL: URL,
            endpointIDHex: String,
            wantPasses: Bool,
            cacheDirectory: URL
        ) {
            self.socketURL = socketURL
            self.endpointIDHex = endpointIDHex
            self.wantPasses = wantPasses
            self.cacheDirectory = cacheDirectory
        }
    }

    public struct Handlers: Sendable {
        public var onRelayPasses: @Sendable ([IrxRelayCredential]) async -> Void
        public var onHintUpdate: @Sendable (_ endpointIDHex: String, _ relayURL: String) async -> Void
        public var onDirectory: @Sendable (CTLDirectoryPayload) async -> Void
        public var onSnapshotComplete: @Sendable (_ rev: Int) async -> Void

        public init(
            onRelayPasses: @escaping @Sendable ([IrxRelayCredential]) async -> Void,
            onHintUpdate: @escaping @Sendable (String, String) async -> Void,
            onDirectory: @escaping @Sendable (CTLDirectoryPayload) async -> Void,
            onSnapshotComplete: @escaping @Sendable (Int) async -> Void
        ) {
            self.onRelayPasses = onRelayPasses
            self.onHintUpdate = onHintUpdate
            self.onDirectory = onDirectory
            self.onSnapshotComplete = onSnapshotComplete
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
    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var backoff: Duration = .seconds(1)
    private static let maxBackoff: Duration = .seconds(30)

    /// Frame router probe: read only the discriminator, then decode the
    /// exact generated type. Unknown types are journaled and skipped so a
    /// newer server can add fact kinds without breaking installed clients
    /// (the additive-evolution contract).
    private struct TypeProbe: Decodable {
        let type: String
    }

    private static let decoder: JSONDecoder = {
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
    }()

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
        cursorCache = IrxDiskCache(
            fileURL: configuration.cacheDirectory
                .appendingPathComponent("control-plane-cursor.json")
        )
    }

    // MARK: - Lifecycle

    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
        journal.record("control-plane", "started")
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        journal.record("control-plane", "stopped")
    }

    /// Foreground reset: reconnect NOW with a fresh token instead of waiting
    /// out whatever backoff a background suspension left behind.
    public func kick() {
        loop?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        backoff = .seconds(1)
        loop = Task { await self.run() }
        journal.record("control-plane", "kicked")
    }

    // MARK: - Connection loop

    private func run() async {
        while !Task.isCancelled {
            do {
                try await connectAndServe()
            } catch is CancellationError {
                return
            } catch {
                journal.record(
                    "control-plane", "socket-ended",
                    ["error": String(describing: error)]
                )
            }
            if Task.isCancelled { return }
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

    private func connectAndServe() async throws {
        guard let tokens = try await tokenPair() else {
            throw IrxConnectionError.closed(nil)
        }
        var request = URLRequest(url: configuration.socketURL)
        request.setValue("Bearer \(tokens.access)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.refresh, forHTTPHeaderField: "x-stack-refresh-token")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()

        let hello = CTLHello(
            payload: CTLHelloPayload(
                endpointID: configuration.endpointIDHex,
                haveRev: cursorCache.load()?.haveRev,
                wantPasses: configuration.wantPasses
            ),
            type: .hello,
            v: 1
        )
        let helloData = try JSONEncoder().encode(hello)
        try await task.send(.string(String(decoding: helloData, as: UTF8.self)))
        journal.record(
            "control-plane", "hello-sent",
            ["have_rev": cursorCache.load()?.haveRev.map(String.init) ?? "-"]
        )

        while !Task.isCancelled {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let raw): data = raw
            @unknown default: continue
            }
            await route(data)
        }
    }

    private func route(_ data: Data) async {
        guard let probe = try? Self.decoder.decode(TypeProbe.self, from: data) else {
            journal.record("control-plane", "frame-unparseable")
            return
        }
        do {
            switch probe.type {
            case "hello_ack":
                let ack = try Self.decoder.decode(CTLHelloACK.self, from: data)
                journal.record(
                    "control-plane", "hello-ack",
                    [
                        "session": ack.payload.sessionID,
                        "resumed_from": ack.payload.resumedFromRev.map(String.init) ?? "snapshot",
                    ]
                )
            case "relay_passes":
                let fact = try Self.decoder.decode(CTLRelayPasses.self, from: data)
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
                await handlers.onRelayPasses(credentials)
            case "hint_update":
                let fact = try Self.decoder.decode(CTLHintUpdate.self, from: data)
                journal.record(
                    "control-plane", "hint-update",
                    [
                        "rev": String(fact.rev),
                        "endpoint": String(fact.payload.endpointID.prefix(12)),
                        "relay": fact.payload.homeRelayURL,
                    ]
                )
                await handlers.onHintUpdate(
                    fact.payload.endpointID, fact.payload.homeRelayURL)
            case "directory":
                let fact = try Self.decoder.decode(CTLDirectory.self, from: data)
                journal.record(
                    "control-plane", "directory",
                    [
                        "rev": String(fact.rev),
                        "bindings": String(fact.payload.bindings.count),
                    ]
                )
                await handlers.onDirectory(fact.payload)
                for binding in fact.payload.bindings {
                    if let relay = binding.homeRelayURL {
                        await handlers.onHintUpdate(binding.endpointID, relay)
                    }
                }
            case "snapshot_complete":
                let fact = try Self.decoder.decode(CTLSnapshotComplete.self, from: data)
                cursorCache.save(IrxControlPlaneCursor(haveRev: fact.rev))
                backoff = .seconds(1)
                journal.record(
                    "control-plane", "snapshot-complete", ["rev": String(fact.rev)]
                )
                await handlers.onSnapshotComplete(fact.rev)
            case "error":
                let fact = try Self.decoder.decode(CTLError.self, from: data)
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
