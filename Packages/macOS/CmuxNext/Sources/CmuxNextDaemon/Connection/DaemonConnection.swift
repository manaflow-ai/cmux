import Foundation
import Synchronization
import os

/// The control-plane connection: one socket for `subscribe` and mutations.
///
/// Handshake per (re)connect: `identify` (check app, protocol 12, required
/// capabilities) -> `set-client-info` -> `subscribe{deltas}`. Events that
/// arrive during the handshake are held and released right after the
/// synthetic `.connected` event, so a consumer that fetches `list-workspaces`
/// on `.connected` sees every later delta and misses none.
///
/// Events are decoded on the socket's reader thread (never the main actor)
/// and stamped with a monotonic `sequence`; `snapshot()` returns the
/// sequence barrier its tree supersedes, so a store can drop older events
/// exactly.
///
/// On EOF it emits `.disconnected`, fails pending requests, and reconnects
/// through `endpointProvider` (which re-runs `server ensure`, restarting a
/// crashed daemon) with capped backoff on the injected clock.
public actor DaemonConnection {
    public typealias EndpointProvider = @Sendable () async throws -> DaemonEndpoint

    public struct Configuration: Sendable {
        public var clientName: String
        public var requiredCapabilities: [String]
        public var advertisedCapabilities: [String]
        public var treeEvents: TreeEventMode
        /// Reconnect delays; the last one repeats.
        public var backoff: [Duration]
        /// Deadline for every control-plane request (architecture.md 5a).
        /// A miss throws `DaemonError.timedOut`; nil disables it (tests only).
        public var requestTimeout: Duration?
        /// Deadline for `list-workspaces` snapshots, which can be large.
        public var snapshotTimeout: Duration?
        /// Deadline for commands that launch a terminal host
        /// (`TerminalSpawningRequest`): cmux-tui's own 3 s launch bound plus margin.
        public var spawnTimeout: Duration?
        /// Per-terminal `env` the convenience spawn calls send when the daemon
        /// supports `terminal-env-v1` and the caller passed none. Nil sends none.
        public var terminalEnvironment: (@Sendable () async -> [String: String])?

        public init(
            clientName: String = "cmux-next",
            requiredCapabilities: [String] = DaemonCapabilities.required,
            advertisedCapabilities: [String] = DaemonCapabilities.advertised,
            treeEvents: TreeEventMode = .deltas,
            backoff: [Duration] = [.milliseconds(50), .milliseconds(250), .seconds(1), .seconds(2)],
            requestTimeout: Duration? = DaemonConnection.defaultRequestTimeout,
            snapshotTimeout: Duration? = .seconds(10),
            spawnTimeout: Duration? = DaemonConnection.defaultSpawnTimeout,
            terminalEnvironment: (@Sendable () async -> [String: String])? = TerminalEnvironment.shared()
        ) {
            self.clientName = clientName
            self.requiredCapabilities = requiredCapabilities
            self.advertisedCapabilities = advertisedCapabilities
            self.treeEvents = treeEvents
            self.backoff = backoff
            self.requestTimeout = requestTimeout
            self.snapshotTimeout = snapshotTimeout
            self.spawnTimeout = requestTimeout == nil ? nil : spawnTimeout
            self.terminalEnvironment = terminalEnvironment
        }
    }

    private enum Phase {
        case idle
        case connecting
        case ready(LineTransport, serial: UInt64)
        case waiting
        case closed
    }

    public nonisolated let events: AsyncThrowingStream<DaemonEventEnvelope, any Error>
    private nonisolated let continuation: AsyncThrowingStream<DaemonEventEnvelope, any Error>.Continuation

    let configuration: Configuration
    private let endpointProvider: EndpointProvider
    private let clock: any Clock<Duration>
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon")
    private var phase: Phase = .idle
    private var serial: UInt64 = 0
    private var reconnectTask: Task<Void, Never>?

    /// Identity of the current (or last) daemon.
    public private(set) var identity: DaemonIdentity?
    public private(set) var endpoint: DaemonEndpoint?

    public init(
        configuration: Configuration = Configuration(),
        clock: any Clock<Duration> = ContinuousClock(),
        endpointProvider: @escaping EndpointProvider
    ) {
        self.configuration = configuration
        self.clock = clock
        self.endpointProvider = endpointProvider
        // concurrency-allow: drained at once by the store pump into the bounded EventInbox
        (events, continuation) = AsyncThrowingStream.makeStream(of: DaemonEventEnvelope.self, bufferingPolicy: .unbounded)
    }

    /// Connects to a fixed socket (tests, dev tools).
    public init(endpoint: DaemonEndpoint, configuration: Configuration = Configuration(), clock: any Clock<Duration> = ContinuousClock()) {
        self.init(configuration: configuration, clock: clock, endpointProvider: { endpoint })
    }

    /// First connect. Throws when the daemon is unreachable or incompatible;
    /// afterwards the connection reconnects by itself until `close()`.
    @discardableResult
    public func start() async throws -> DaemonIdentity {
        guard case .idle = phase else {
            if let identity { return identity }
            throw DaemonError.notConnected
        }
        return try await connectOnce()
    }

    /// Stops reconnecting, closes the socket, and finishes `events`.
    public func close() {
        reconnectTask?.cancel()
        reconnectTask = nil
        if case .ready(let transport, _) = phase { transport.close() }
        phase = .closed
        continuation.finish()
    }

    public var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    /// Control-plane deadline default: 2 s (architecture.md 5a).
    public static let defaultRequestTimeout: Duration = .seconds(2)
    /// Terminal host launches: cmux-tui waits up to 2 s for the host
    /// handshake after a 1 s connect retry window.
    public static let defaultSpawnTimeout: Duration = .seconds(5)

    /// Sends one command and decodes its response. Fails with
    /// `DaemonError.timedOut` after `timeout` (default: the configured
    /// `requestTimeout`) instead of waiting forever.
    public func request<R: DaemonRequest>(_ request: R) async throws -> R.Response {
        let spawns = R.self is any TerminalSpawningRequest.Type
        return try await self.request(request, timeout: spawns ? configuration.spawnTimeout : configuration.requestTimeout)
    }

    public func request<R: DaemonRequest>(_ request: R, timeout: Duration?) async throws -> R.Response {
        guard case .ready(let transport, _) = phase else { throw DaemonError.notConnected }
        return try await Self.perform(request, on: transport, timeout: timeout)
    }

    /// The event sequence this connection has routed so far, or nil when
    /// not connected. Taken after a command's reply, it is a write barrier:
    /// once `DaemonStore.appliedSequence` reaches it, the store reflects
    /// every event the daemon emitted before that reply (the reply's
    /// `eventBarrier` is at most this). Sequences grow across reconnects.
    public func eventSequence() -> UInt64? {
        guard case .ready(let transport, let serial) = phase else { return nil }
        return DaemonEventEnvelope.sequence(serial: serial, index: transport.routedEventCount)
    }

    /// Sends one `cmux.protocol/2` resource request (`ResourceRequestEnvelope`)
    /// on the control socket and decodes its `result`.
    func resourceRequest<R: Decodable>(_ envelope: @escaping @Sendable (UInt64) -> ResourceRequestEnvelope,
                                       as type: R.Type) async throws -> R {
        guard case .ready(let transport, _) = phase else { throw DaemonError.notConnected }
        let response = try await transport.request(cmd: envelope(0).operation, timeout: configuration.requestTimeout) { id in
            try envelope(id).line()
        }
        return try ResourceRequestEnvelope.decodeResult(R.self, from: response.line)
    }

    /// `list-workspaces` plus the sequence of the last event it supersedes.
    public func snapshot() async throws -> (tree: DaemonTree, barrier: UInt64) {
        guard case .ready(let transport, let serial) = phase else { throw DaemonError.notConnected }
        let response = try await transport.request(cmd: ListWorkspacesRequest.command, timeout: configuration.snapshotTimeout) { id in
            try WireCoding.encodeRequest(ListWorkspacesRequest(), id: id)
        }
        var tree = try WireCoding.decodeResponse(DaemonTree.self, from: response.line)
        if identity?.supports(DaemonCapabilities.savedTabGroups) == true, tree.savedTabGroups.isEmpty {
            // Saved groups are not part of `list-workspaces`. Their changes
            // emit `tree-changed`, which triggers this snapshot again.
            tree.savedTabGroups = try await Self.perform(ListSavedTabGroupsRequest(), on: transport,
                                                         timeout: configuration.requestTimeout).savedGroups
            tree.linkSavedTabGroups()
        }
        return (tree, DaemonEventEnvelope.sequence(serial: serial, index: response.eventBarrier))
    }

    static func perform<R: DaemonRequest>(_ request: R, on transport: LineTransport,
                                          timeout: Duration? = defaultRequestTimeout) async throws -> R.Response {
        let response = try await transport.request(cmd: R.command, timeout: timeout) { id in
            try WireCoding.encodeRequest(request, id: id)
        }
        return try WireCoding.decodeResponse(R.Response.self, from: response.line)
    }

    // MARK: - Connect / reconnect

    private func connectOnce() async throws -> DaemonIdentity {
        phase = .connecting
        serial += 1
        let serial = serial
        do {
            let endpoint = try await endpointProvider()
            let transport = try LineTransport(path: endpoint.socketPath)
            let gate = EventGate()
            let continuation = continuation
            transport.start(
                onEvent: { name, line, index in
                    let envelope = DaemonEventEnvelope(
                        sequence: DaemonEventEnvelope.sequence(serial: serial, index: index),
                        event: DaemonEvent.decode(name: name, line: line))
                    gate.deliver(envelope) { continuation.yield($0) }
                },
                onClose: { [weak self] reason in
                    // task-owner: hop onto the actor; transportClosed ignores a stale serial
                    Task { await self?.transportClosed(serial: serial, reason: reason) }
                }
            )
            let identity = try await handshake(transport)
            guard self.serial == serial, !isClosedPhase else {
                transport.close()
                throw DaemonError.connectionClosed(reason: "superseded")
            }
            let generationChanged = self.identity.map {
                $0.generation != identity.generation || $0.registryID != identity.registryID
            } ?? false
            self.identity = identity
            self.endpoint = endpoint
            phase = .ready(transport, serial: serial)
            let connected = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: serial, index: 0),
                                                event: .connected(identity, generationChanged: generationChanged))
            gate.open(first: connected) { continuation.yield($0) }
            logger.info("connected to cmux-tui \(identity.session, privacy: .public) pid \(identity.pid) gen \(identity.generation.rawValue, privacy: .public)")
            return identity
        } catch {
            if case .connecting = phase { phase = .waiting }
            throw error
        }
    }

    private var isClosedPhase: Bool {
        if case .closed = phase { return true }
        return false
    }

    private func handshake(_ transport: LineTransport) async throws -> DaemonIdentity {
        let identity = try await Self.perform(IdentifyRequest(), on: transport, timeout: configuration.requestTimeout)
        guard identity.app == "cmux-tui" else {
            transport.close()
            throw DaemonError.wrongApp(identity.app)
        }
        guard identity.protocolVersion == 12 else {
            transport.close()
            throw DaemonError.unsupportedProtocol(identity.protocolVersion)
        }
        let missing = configuration.requiredCapabilities.filter { !identity.supports($0) }
        guard missing.isEmpty else {
            transport.close()
            throw DaemonError.missingCapabilities(missing)
        }
        _ = try await Self.perform(
            SetClientInfoRequest(name: configuration.clientName, kind: "frontend", capabilities: configuration.advertisedCapabilities),
            on: transport, timeout: configuration.requestTimeout
        )
        _ = try await Self.perform(SubscribeRequest(treeEvents: configuration.treeEvents), on: transport,
                                   timeout: configuration.requestTimeout)
        return identity
    }

    private func transportClosed(serial: UInt64, reason: TransportCloseReason) {
        guard serial == self.serial else { return }
        if case .closed = phase { return }
        if case .ready = phase {} else if case .connecting = phase {} else { return }
        phase = .waiting
        let detail: String = switch reason {
        case .closedByClient: "closed"
        case .daemonShutdown: "daemon shut down"
        case .lost(let text): text
        }
        logger.info("cmux-tui connection lost: \(detail, privacy: .public)")
        continuation.yield(DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: serial, index: DaemonEventEnvelope.lastIndex),
                                               event: .disconnected(reason: detail)))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    private func reconnectLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            let delays = configuration.backoff
            if !delays.isEmpty {
                let delay = delays[min(attempt, delays.count - 1)]
                do { try await clock.sleep(for: delay) } catch { break }
            }
            if isClosedPhase { break }
            do {
                _ = try await connectOnce()
                break
            } catch let error as DaemonError {
                switch error {
                case .wrongApp, .unsupportedProtocol, .missingCapabilities:
                    // Incompatible daemon: retrying cannot help.
                    logger.error("cmux-tui reconnect failed permanently: \(error.description, privacy: .public)")
                    reconnectTask = nil
                    phase = .closed
                    continuation.finish(throwing: error)
                    return
                default:
                    logger.info("cmux-tui reconnect attempt \(attempt) failed: \(error.description, privacy: .public)")
                }
            } catch {
                logger.info("cmux-tui reconnect attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
            }
            attempt += 1
        }
        reconnectTask = nil
    }
}
