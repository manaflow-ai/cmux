import CmuxNextWakeups
public import Foundation
public import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import os

/// The control-plane connection: one socket for `subscribe` and mutations.
///
/// Handshake per (re)connect: `identify` (check app, protocol 12, required
/// capabilities) -> `set-client-info` -> `subscribe{deltas}`. Events that
/// arrive during the handshake are held and released right after the
/// synthetic `.connected` event, so a consumer that fetches `list-workspaces`
/// on `.connected` sees every later delta and misses none.
///
/// Events are decoded on the connection's decode lane (``DecodeLane``, never the reader or the main actor)
/// and stamped with a monotonic `sequence`; `snapshot()` returns the
/// sequence barrier its tree supersedes, so a store can drop older events
/// exactly. A consumer that takes them with ``consumeEvents(_:)`` gets each
/// on that thread, with no cooperative-pool job between the socket and it
/// (``DaemonEventRoute``). `events` has that one consumer; any other one
/// takes ``subscribe(filter:limit:)``: the events its filter matches, in
/// order, in a bounded inbox of its own that no other consumer waits for.
///
/// On EOF it emits `.disconnected`, fails pending requests, and reconnects
/// through `endpointProvider` (which re-runs `server ensure`, restarting a
/// crashed daemon). Attempts are spaced by one capped backoff across
/// consecutive drops (reset only after a connection stays up for
/// `healthyAfter`), and after `retry.timedRetries` failures no timer runs:
/// the loop waits for the daemon socket to change or `retryWake` to fire.
/// After `retry.socketRetries` failures that a new socket woke (a daemon
/// that dies on connect) only `retryWake` does.
///
/// With ``DaemonConnectionConfiguration/reportsDiagnosticSites`` the reader decodes each
/// `server-diagnostic-site` line once into its transport's relay and routes the event on as `unknown` with no
/// payload; once the handshake names the daemon life, the sites reach ``diagnosticSites`` as sightings of it.
public actor DaemonConnection {
    public typealias EndpointProvider = @Sendable () async throws -> DaemonEndpoint

    /// `DaemonConnectionConfiguration`.
    public typealias Configuration = DaemonConnectionConfiguration

    private enum Phase {
        case idle
        case connecting
        case ready(DaemonReadyConnection)
        case waiting
        case closed
    }

    /// The events for this connection's one consumer (``DaemonEventStream``).
    public nonisolated let events: DaemonEventStream
    /// Identifies this event source; pair it with an envelope's connection serial.
    public nonisolated let eventSourceID: UUID = UUID()
    /// The `mutation_id`s caused scopes sent on this connection, which name their echoes' cause.
    public nonisolated let mutationCauses = MutationCauseLedger()
    /// The daemon's diagnostic sites this connection read, each once per daemon life, held until a sink is installed.
    public nonisolated let diagnosticSites = DaemonDiagnosticSiteRelay<DaemonDiagnosticSite.Sighting>()
    /// Where events go: `events`, or the consumer of ``consumeEvents(_:)``; and each subscriber.
    nonisolated let route: DaemonEventRoute

    let configuration: Configuration
    private let endpointProvider: EndpointProvider
    let clock: any Clock<Duration>
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon")
    private var phase: Phase = .idle {
        // The request path's snapshot follows every phase change.
        didSet {
            let snapshot = ready
            admitted.withLock { $0 = snapshot }
        }
    }
    /// The ready connection as the request path reads it, with no actor hop: the `Mutex` snapshot of
    /// `phase`, nil when not ready.
    private nonisolated let admitted = Mutex<DaemonReadyConnection?>(nil)
    private(set) var serial: UInt64 = 0
    /// The open `session.events` stream id (`DaemonConnection+SessionEvents`).
    var sessionStream: String?
    private var reconnectTask: Task<Void, Never>?
    private var pacer: RetryPacer
    private let wake: RetryWake
    private let healthy: DemandTimer
    public nonisolated let heartbeat: ConnectionHeartbeat

    /// Identity of the current (or last) daemon.
    public private(set) var identity: DaemonIdentity?
    /// The ready connection's `client-hello` `user_origin_allowed` (`HandshakeLines.Replies`); false when not ready.
    public var userOriginAllowed: Bool { if case .ready(let ready) = phase { ready.userOriginAllowed } else { false } }
    public private(set) var endpoint: DaemonEndpoint?
    /// Quiet handoff (`DaemonConnection+QuietHandoff`): requests in flight and the requests held while
    /// a handoff runs, counted and parked without the actor; the running hold's limit timer.
    nonisolated let handoffGate: QuietHandoffGate
    var handoffHoldTimer: DemandTimer?
    /// Waits for a ready connection newer than `after` (`DaemonConnection+ReadyWait`), each with its limit.
    var readyWaits: [UInt64: (after: UInt64, continuation: OnceContinuation<Bool, OnceContinuationError>, timer: DemandTimer)] = [:]
    var readyWaitNext: UInt64 = 0
    /// Shows a request refused because it names a pane still opening (``PaneNotReady``); see ``observePaneNotReady(_:)``.
    /// A `Mutex`, as ``admitted``: the request path reads it from the caller's executor, with no actor hop.
    private nonisolated let paneNotReadyObserver = Mutex<(@Sendable (PaneNotReady) -> Void)?>(nil)
    /// The launch's first snapshot, fetched right after the handshake (``prefetchSnapshot()``).
    var prefetchedSnapshot: (serial: UInt64, fetch: Task<(tree: DaemonTree, barrier: UInt64), any Error>)?

    public init(
        configuration: Configuration = Configuration(),
        clock: any Clock<Duration> = ContinuousClock(),
        endpointProvider: @escaping EndpointProvider
    ) {
        self.configuration = configuration
        self.clock = clock
        self.endpointProvider = endpointProvider
        pacer = RetryPacer(configuration.retry)
        wake = configuration.retryWake ?? RetryWake(owner: "DaemonConnection.reconnect")
        // timer-class-allow: off main: it marks a connection healthy on the connection's actor; no main-thread job
        healthy = DemandTimer(owner: "DaemonConnection.healthy", clock: clock)
        let heartbeat = ConnectionHeartbeat()
        self.heartbeat = heartbeat
        // The heartbeat asks on its shown cadence while a request waits for its reply.
        handoffGate = QuietHandoffGate(observe: configuration.handoffWaits,
                                       busyEdge: { [heartbeat] gate in heartbeat.requestsWaiting { gate.requestsInFlight > 0 } })
        // The events no consumer took yet wait in the route's bounded EventInbox backlog; past
        // DaemonEventRoute.highWater bytes of them, while a stream consumer takes them, the reader stops reading the socket.
        let route = DaemonEventRoute()
        self.route = route
        self.events = DaemonEventStream(route: route)
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

    /// Stops reconnecting, closes the socket, and finishes `events` and every subscription.
    public func close() {
        healthy.cancel()
        heartbeat.stop()
        reconnectTask?.cancel()
        reconnectTask = nil
        if case .ready(let ready) = phase { ready.transport.close() }
        phase = .closed
        releaseHandoffHold()
        endReadyWaits()
        route.finish()
    }

    /// False while the connected daemon left its heartbeat's asks unanswered and its process is alive
    /// (``ConnectionHeartbeat/answering``): the connection stays open and its requests keep waiting.
    public nonisolated var daemonAnswering: Bool { heartbeat.answering }

    /// Calls `observer` with ``daemonAnswering`` after each change and at each unanswered ask past the misses,
    /// off the main actor; nil stops.
    public nonisolated func observeAnswering(_ observer: (@Sendable (Bool) -> Void)?) {
        heartbeat.observeAnswering(observer)
    }

    public var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    /// Control-plane deadline default: 2 s (architecture.md 5a).
    public static let defaultRequestTimeout: Duration = .seconds(2)
    /// The terminal start deadline: a command that starts a terminal
    /// answers once its host is up. cmux-tui bounds one host launch by its
    /// 2 s handshake after a 1 s connect retry window, and starts the hosts
    /// of a burst of creates in parallel (8 at a time) while committing
    /// them in order, so 5 s also covers a create queued behind others.
    /// Control requests that start a terminal use this plus 1 s
    /// (`ControlRouter.terminalStartDeadline`).
    public static let defaultSpawnTimeout: Duration = .seconds(5)

    /// Sends one command and decodes its response. Fails with
    /// `DaemonError.timedOut` after `timeout` (default: the configured
    /// `requestTimeout`) instead of waiting forever.
    /// Runs on the caller's executor, never the connection's actor (`request(_:timeout:)`).
    /// A terminal-starting request gets Ghostty's shell-integration arguments when the daemon that
    /// carries it serves them, decided after the quiet-handoff gate (a request held through a handoff
    /// goes to the next daemon).
    public nonisolated func request<R: DaemonRequest>(_ request: R) async throws -> R.Response {
        guard R.self is any TerminalSpawningRequest.Type else {
            return try await self.request(request, timeout: configuration.requestTimeout)
        }
        do {
            return try await sendAdmitted(request, timeout: configuration.spawnTimeout, forDaemon: Self.withShellIntegration)
        } catch DaemonError.timedOut(let what) {
            // cmux-tui keeps starting the terminal after the client gave up.
            throw DaemonError.terminalStartTimedOut(what)
        }
    }

    /// A terminal start the daemon makes exactly once under its client-chosen terminal id (`new-tab` with
    /// `terminal-placement-env-v1`): sent once, with the shell-integration arguments ``request(_:)`` adds, and answered
    /// by its reply or the connection's end (``LineTransport`` fails every pending request on close). No client deadline
    /// decides it: the start's outcome is the daemon's (principled-audit R5, R-L5).
    nonisolated func requestAwaitingStart<R: TerminalSpawningRequest>(_ request: R) async throws -> R.Response {
        try await sendAdmitted(request, timeout: nil, forDaemon: Self.withShellIntegration)
    }

    /// `request` with Ghostty's shell-integration arguments when the daemon that carries it serves them.
    private static func withShellIntegration<R: DaemonRequest>(_ request: R, identity: DaemonIdentity) -> R {
        guard identity.supports(DaemonCapability.terminalShellArgs.rawValue),
              let carrier = request as? any ShellIntegrationArgumentCarrying,
              let integrated = carrier.addingShellIntegrationArguments() as? R else { return request }
        return integrated
    }

    /// Runs on the caller's executor with no actor hop: it reads the ready connection from
    /// its `Mutex` snapshot and passes the quiet-handoff gate with atomics only.
    public nonisolated func request<R: DaemonRequest>(_ request: R, timeout: Duration?) async throws -> R.Response {
        try await sendAdmitted(request, timeout: timeout) { request, _ in request }
    }

    /// Passes the quiet-handoff gate, then sends `request` as `forDaemon` makes it for the identity of
    /// the ready connection that carries it.
    private nonisolated func sendAdmitted<R: DaemonRequest>(_ request: R, timeout: Duration?,
                                                            forDaemon: (R, DaemonIdentity) -> R) async throws -> R.Response {
        await handoffGate.enter(passes: Self.passesHandoffHold)
        defer { handoffGate.leave() }
        guard let ready = admittedConnection else { throw DaemonError.notConnected }
        try R.requireServed(by: ready.identity)
        let request = forDaemon(request, ready.identity)
        // Before the line goes out: the echo can arrive before the reply.
        DaemonCommandScope.recordEchoTransaction(of: request, in: mutationCauses)
        let response: R.Response
        do {
            response = try await Self.perform(request, on: ready.transport, timeout: timeout)
        } catch let refused as PaneNotReady {
            throw reported(refused)
        }
        DaemonCommandScope.noteCreated(by: request, response: response)
        return response
    }

    /// Rule (a) of the P0 2026-10-30, at the one place every sender's request goes through: a request refused because
    /// it names a pane still opening shows why once, for every sender (a `DaemonService` funnel, or a handler that calls
    /// this connection itself). A scope that answers failures (`action.run` from the CLI or MCP,
    /// ``DaemonCommandScope/answersFailures``) answers the refusal itself, so it shows nothing here; a person's run
    /// (a key, the menu, the palette) has a person scope that answers nobody, so it shows here. The returned error is
    /// marked shown, so no reporter shows it again.
    private nonisolated func reported(_ refused: PaneNotReady) -> PaneNotReady {
        guard DaemonCommandScope.current?.answersFailures != true, let observer = paneNotReadyObserver.withLock({ $0 }) else { return refused }
        var shown = refused
        shown.shown = true
        observer(shown)
        return shown
    }

    /// Sets what shows a request refused because it names a pane still opening (``PaneNotReady``) when no open action
    /// scope answers it; `DaemonService` sets it on each connection it makes, from main with no hop (a `Mutex`).
    public nonisolated func observePaneNotReady(_ observer: (@Sendable (PaneNotReady) -> Void)?) {
        paneNotReadyObserver.withLock { $0 = observer }
    }

    /// The event sequence this connection has routed so far, or nil when
    /// not connected. Taken after a command's reply, it is a write barrier:
    /// once `DaemonStore.appliedSequence` reaches it, the store reflects
    /// every event the daemon emitted before that reply (the reply's
    /// `eventBarrier` is at most this). Sequences grow across reconnects.
    public func eventSequence() -> UInt64? { ready?.eventSequence }

    /// Sends one `cmux.protocol/2` resource request (``DaemonResourceLine``) on the control socket
    /// and decodes its `result`; `timeout` replaces the request deadline.
    /// `onTransport` runs on the caller's executor with the transport that carries the request, after
    /// the handoff wait and before the line is sent; it throws to cancel the request. No actor hop, as
    /// `request(_:timeout:)`.
    nonisolated func resourceRequest<Line: DaemonResourceLine, R: Decodable>(_ envelope: @escaping @Sendable (UInt64) -> Line,
                                                                              as type: R.Type, timeout: Duration? = nil,
                                                                              onTransport: (LineTransport) throws -> Void = { _ in }) async throws -> R {
        await handoffGate.enter(passes: Self.passesHandoffHold)
        defer { handoffGate.leave() }
        guard let ready = admittedConnection else { throw DaemonError.notConnected }
        try onTransport(ready.transport)
        let response = try await ready.transport.request(cmd: DaemonCommandName(wire: envelope(0).operation), timeout: timeout ?? configuration.requestTimeout) { id in
            try envelope(id).lineData()
        }
        return try ResourceRequestEnvelope.decodeResult(R.self, from: response)
    }

    /// Delivers an event the connection itself produced, after those routed so far.
    func yieldEvent(_ envelope: DaemonEventEnvelope) {
        route.emit(DaemonEventEnvelope(sequence: envelope.sequence, event: envelope.event, sourceID: eventSourceID, cause: envelope.cause))
    }

    /// Takes this connection's events instead of `events`, in order, until they end: the ones the
    /// route's bounded backlog holds (on the calling task), then each later one on the thread that
    /// produced it (the reader for every daemon event; the actor for `connected` and `disconnected`).
    /// The echo of a person's action reaches `deliver` with no cooperative-pool job after the socket
    /// read. One consumer per connection; returns when the connection finishes,
    /// throwing what ended it, or when the calling task is cancelled.
    ///
    /// - Parameter deliver: Takes one event; runs under ``DaemonEventRoute``'s lock, so it must not
    ///   block or call back into the connection.
    nonisolated func consumeEvents(_ deliver: @escaping DaemonEventRoute.Sink) async throws {
        route.takeStream()
        route.attach(deliver)
        defer { route.detach() }
        try await route.ended()
    }

    /// The admitted control session, or nil when not connected.
    var ready: DaemonReadyConnection? {
        guard case .ready(let ready) = phase else { return nil }
        return ready
    }

    /// ``ready`` from any executor: the snapshot `phase` writes on every change.
    nonisolated var admittedConnection: DaemonReadyConnection? { admitted.withLock { $0 } }

    static func perform<R: DaemonRequest>(_ request: R, on transport: LineTransport,
                                          timeout: Duration? = defaultRequestTimeout) async throws -> R.Response {
        try await DaemonRequestExecutor(transport: transport).perform(request, timeout: timeout)
    }

    // MARK: - Connect / reconnect

    private func connectOnce() async throws -> DaemonIdentity {
        phase = .connecting
        serial += 1
        let serial = serial
        do {
            let endpoint = try await endpointProvider()
            DaemonLaunchTimings.shared.mark("daemon.endpoint_resolved")
            let transport = try await LineTransport.open(path: endpoint.socketPath, bridge: endpoint.bridge,
                                                         role: configuration.role == .pageRelay ? .pageRelay : .control,
                                                         stats: endpoint.wireStats, hangs: configuration.hangWatch)
            DaemonLaunchTimings.shared.mark("daemon.socket_connected")
            let gate = EventGate()
            let route = route
            let eventSourceID = eventSourceID
            let raw = configuration.role == .pageRelay
            let decoder = transport.decoder
            let mutationCauses = mutationCauses
            // The subscribe of the handshake starts the daemon's replay before identify is read: held until then.
            let transportSites = configuration.reportsDiagnosticSites ? DaemonDiagnosticSiteRelay<DaemonDiagnosticSite>() : nil
            // Each event decodes on the connection's decode lane; the reader waits for the stream's consumer
            // after the line.
            route.resetReaderRelease()
            transport.start(
                dispatch: EventDispatch(weigh: { _, _ in .heavy }, readerWait: { route.waitWhileReaderParked() },
                                        wakeReader: { route.wakeParkedReader() }),
                onCausedEvent: { [weak self] name, line, index, wireCause in
                    let event: DaemonEvent
                    if let transportSites, name == DaemonDiagnosticSite.eventName {
                        // Routed on with no payload: the sequence counts it; nothing but the relay reads it.
                        if let site = try? decoder.decode(DaemonDiagnosticSite.self, from: line) { transportSites.deliver(site) }
                        event = .unknown(name: name, payload: .null)
                    } else {
                        event = raw ? DaemonEvent.raw(name: name, line: line, decoder: decoder)
                            : DaemonEvent.decode(name: name, line: line, decoder: decoder)
                    }
                    let envelope = DaemonEventEnvelope(
                        sequence: DaemonEventEnvelope.sequence(serial: serial, index: index), event: event, sourceID: eventSourceID,
                        cause: event.cause(wire: wireCause, recorded: mutationCauses))
                    if case .sessionState(let item) = envelope.event, item.endsStream {
                        // task-owner: hop onto the actor; a stale serial is ignored there
                        Task { await self?.sessionStreamEvent(item, serial: serial) }
                    }
                    gate.deliver(envelope) { route.emit($0, bytes: line.count, parksReader: true) }
                },
                onClose: { [weak self] reason in
                    // task-owner: hop onto the actor; transportClosed ignores a stale serial
                    Task { await self?.transportClosed(serial: serial, reason: reason) }
                }
            )
            let (identity, userOriginAllowed) = try await DaemonHandshake(configuration: configuration, logger: logger).run(on: transport)
            guard self.serial == serial, !isClosedPhase else {
                transport.close()
                throw DaemonError.connectionClosed(reason: "superseded")
            }
            let generationChanged = self.identity.map {
                $0.generation != identity.generation || $0.registryID != identity.registryID
            } ?? false
            self.identity = identity
            self.endpoint = endpoint
            let life = DaemonDiagnosticSite.Sighting.life(pid: identity.pid, generation: identity.generation.rawValue)
            transportSites?.install { [diagnosticSites] in diagnosticSites.deliver(.init(site: $0, daemonLife: life)) }
            phase = .ready(DaemonReadyConnection(transport: transport, serial: serial, identity: identity, userOriginAllowed: userOriginAllowed))
            releaseHandoffHold()
            resumeReadyWaits(serial: serial)
            wake.watch(file: endpoint.socketPath, companions: [endpoint.socketPath + ".websocket.json"])
            healthy.schedule(after: configuration.healthyAfter) { [weak self] in await self?.stayedHealthy(serial: serial) }
            if endpoint.bridge != nil || configuration.localHeartbeat {
                heartbeat.start(transport, every: configuration.heartbeat,
                                hidden: endpoint.bridge != nil ? configuration.hiddenHeartbeat : nil, misses: configuration.heartbeatMisses)
            }
            let connected = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: serial, index: 0),
                                                event: .connected(identity, generationChanged: generationChanged), sourceID: eventSourceID)
            gate.open(first: connected) { route.emit($0) }
            // task-owner: one request with the control deadline; a stale serial returns at once
            Task { [weak self] in await self?.openSessionEvents(serial: serial) }
            logger.info("connected to cmux-tui \(identity.session, privacy: .public) pid \(identity.pid) gen \(identity.generation.rawValue, privacy: .public)")
            return identity
        } catch {
            if case .connecting = phase { phase = .waiting }
            throw error
        }
    }

    var isClosedPhase: Bool { if case .closed = phase { true } else { false } }

    private func transportClosed(serial: UInt64, reason: TransportCloseReason) {
        guard serial == self.serial else { return }
        if case .closed = phase { return }
        if case .ready = phase {} else if case .connecting = phase {} else { return }
        phase = .waiting
        healthy.cancel()
        // The connection ended: nothing answers on it, and the next connection's run starts answering.
        heartbeat.stop()
        let detail: String = switch reason {
        case .closedByClient: "closed"
        case .daemonShutdown: "daemon shut down"
        case .lost(let text): text
        }
        logger.info("cmux-tui connection lost: \(detail, privacy: .public)")
        route.emit(DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: serial, index: DaemonEventEnvelope.lastIndex),
                                       event: .disconnected(reason: detail), sourceID: eventSourceID))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    /// Up for `healthyAfter`: the next drop starts the backoff from its first step.
    private func stayedHealthy(serial: UInt64) {
        guard serial == self.serial, case .ready = phase else { return }
        pacer.reset()
    }

    private func reconnectLoop() async {
        // wakeup-allow: backoff: each iteration waits in RetryWake (capped backoff, then events only)
        while !Task.isCancelled {
            // A drop or a failed attempt: space the next one (events only past the budget;
            // in a crash loop a new socket no longer counts, `RetryPolicy.socketRetries`).
            wake.rebaseline()
            let delay = pacer.failed()
            if pacer.socketFailures == pacer.policy.socketRetries {
                logger.error("cmux-tui reconnect: \(self.pacer.socketFailures) new daemon sockets failed; waiting for app activation or a reconnect")
            }
            let cause = await wake.awaitWake(delay: delay, clock: clock, socket: pacer.wakesOnSocket)
            guard cause != .cancelled else { break }
            pacer.woke(cause)
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
                    releaseHandoffHold()
                    endReadyWaits()
                    route.finish(throwing: error)
                    return
                default:
                    logger.info("cmux-tui reconnect attempt \(self.pacer.failures) failed: \(error.description, privacy: .public)")
                    // A restoring owner keeps the timed budget (`DaemonStartup.ownerIsRestoring`).
                    if DaemonStartup.shared.ownerIsRestoring(error) { pacer.reset() }
                }
            } catch {
                logger.info("cmux-tui reconnect attempt \(self.pacer.failures) failed: \(String(describing: error), privacy: .public)")
            }
            if pacer.isExhausted {
                logger.info("cmux-tui reconnect: timed retries spent; waiting for the daemon socket or another event")
            }
        }
        reconnectTask = nil
    }
}
