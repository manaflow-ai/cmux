import CmuxNextWakeups
public import Foundation
import CmuxNextCompat
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
/// crashed daemon). Attempts are spaced by one capped backoff across
/// consecutive drops (reset only after a connection stays up for
/// `healthyAfter`), and after `retry.timedRetries` failures no timer runs:
/// the loop waits for the daemon socket to change or `retryWake` to fire,
/// unless `retry.keepsTrying` (the app's local daemon, whose start can fail
/// for a cause that ends with no event: one attempt per backoff cap).
/// After `retry.socketRetries` failures that a new socket woke (a daemon
/// that dies on connect) only `retryWake` does.
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

    public nonisolated let events: AsyncThrowingStream<DaemonEventEnvelope, any Error>
    /// Identifies this event source; pair it with an envelope's connection serial.
    public nonisolated let eventSourceID: UUID = UUID()
    private nonisolated let continuation: AsyncThrowingStream<DaemonEventEnvelope, any Error>.Continuation

    let configuration: Configuration
    private let endpointProvider: EndpointProvider
    let clock: any Clock<Duration>
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon")
    private var phase: Phase = .idle
    private(set) var serial: UInt64 = 0
    /// The open `session.events` stream id (`DaemonConnection+SessionEvents`).
    var sessionStream: String?
    private var reconnectTask: Task<Void, Never>?
    /// The initial endpoint/handshake attempt, retained so teardown can join it too.
    private var connectTask: Task<DaemonIdentity, any Error>?
    private var pacer: RetryPacer
    private let wake: RetryWake
    private let healthy: DemandTimer
    private nonisolated let heartbeat = ConnectionHeartbeat()

    /// Identity of the current (or last) daemon.
    public private(set) var identity: DaemonIdentity?
    /// The ready connection's `client-hello` `user_origin_allowed` (`HandshakeLines.Replies`); false when not ready.
    public var userOriginAllowed: Bool { if case .ready(let ready) = phase { ready.userOriginAllowed } else { false } }
    public private(set) var endpoint: DaemonEndpoint?
    /// Quiet handoff (`DaemonConnection+QuietHandoff`): requests in flight, the waits for none, and
    /// the requests held while a handoff runs (nil: none runs).
    var inFlight = 0
    var quietWaiters: [CheckedContinuation<Void, Never>] = []
    var handoffHold: [UInt64: CheckedContinuation<Void, Never>]?
    var handoffHoldNext: UInt64 = 0
    var handoffQueue: [CheckedContinuation<Void, Never>] = []
    var handoffHoldTimer: DemandTimer?
    /// Shows a request refused because it names a pane still opening (``PaneNotReady``); see ``observePaneNotReady(_:)``.
    private var paneNotReadyObserver: (@Sendable (PaneNotReady) -> Void)?
    /// Told each time a reconnect fails with the timed retries spent; see ``observeRetriesSpent(_:)``.
    private var retriesSpentObserver: (@Sendable () -> Void)?
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
        healthy = DemandTimer(owner: "DaemonConnection.healthy", clock: clock)
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
        if let identity, !isClosedPhase { return identity }
        let task = try beginInitialAttempt()
        do {
            let identity = try await task.value
            connectTask = nil
            return identity
        } catch {
            connectTask = nil
            throw error
        }
    }

    /// Kept synchronous on the actor so one initial attempt owns its retained task.
    /// Tests can close in this same actor turn before the scheduled attempt enters.
    func beginInitialAttempt() throws -> Task<DaemonIdentity, any Error> {
        guard case .idle = phase, connectTask == nil else { throw DaemonError.notConnected }
        let task = Task { [weak self] in
            guard let self else { throw DaemonError.connectionClosed(reason: "connection deallocated") }
            return try await self.connectOnce()
        }
        connectTask = task
        return task
    }

    /// Stops reconnecting, closes the socket, and finishes `events`.
    public func close() {
        healthy.cancel()
        heartbeat.stop()
        connectTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        if case .ready(let ready) = phase { ready.transport.close() }
        phase = .closed
        releaseHandoffHold()
        continuation.finish()
    }

    /// Also waits for an in-flight endpoint/reconnect attempt to finish before its owner is reaped.
    public func closeAndWait() async {
        let connect = connectTask
        let reconnect = reconnectTask
        close()
        _ = try? await connect?.value
        await reconnect?.value
    }

    /// False while the connected daemon left its heartbeat's asks unanswered and its process is alive
    /// (``ConnectionHeartbeat/answering``): the connection stays open and its requests keep waiting.
    public nonisolated var daemonAnswering: Bool { heartbeat.answering }

    /// Calls `observer` with ``daemonAnswering`` after each change, off the main actor; nil stops.
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
    public func request<R: DaemonRequest>(_ request: R) async throws -> R.Response {
        guard R.self is any TerminalSpawningRequest.Type else {
            return try await self.request(request, timeout: configuration.requestTimeout)
        }
        do {
            return try await self.request(withShellIntegration(request), timeout: configuration.spawnTimeout)
        } catch DaemonError.timedOut(let what) {
            // cmux-tui keeps starting the terminal after the client gave up.
            throw DaemonError.terminalStartTimedOut(what)
        }
    }

    /// A terminal start the daemon makes exactly once under its client-chosen terminal id (`new-tab` with
    /// `terminal-placement-env-v1`): sent once, with the shell-integration arguments ``request(_:)`` adds, and answered
    /// by its reply or the connection's end (``LineTransport`` fails every pending request on close). No client deadline
    /// decides it: the start's outcome is the daemon's (principled-audit R5, R-L5).
    func requestAwaitingStart<R: TerminalSpawningRequest>(_ request: R) async throws -> R.Response {
        try await self.request(withShellIntegration(request), timeout: nil)
    }

    /// `request` with Ghostty's shell-integration arguments when this daemon serves them.
    private func withShellIntegration<R: DaemonRequest>(_ request: R) -> R {
        guard identity?.supports(DaemonCapability.terminalShellArgs.rawValue) == true,
              let carrier = request as? any ShellIntegrationArgumentCarrying,
              let integrated = carrier.addingShellIntegrationArguments() as? R else { return request }
        return integrated
    }

    public func request<R: DaemonRequest>(_ request: R, timeout: Duration?) async throws -> R.Response {
        await waitOutHandoff()
        guard let ready else { throw DaemonError.notConnected }
        requestStarted()
        defer { requestEnded() }
        try R.requireServed(by: identity)
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
    /// this connection itself). An open action scope (`action.run` from the CLI or MCP) answers the refusal itself, so
    /// it shows nothing here. The returned error is marked shown, so no reporter shows it again.
    private func reported(_ refused: PaneNotReady) -> PaneNotReady {
        guard DaemonCommandScope.current?.isOpen != true, let paneNotReadyObserver else { return refused }
        var shown = refused
        shown.shown = true
        paneNotReadyObserver(shown)
        return shown
    }

    /// Sets what shows a request refused because it names a pane still opening (``PaneNotReady``) when no open action
    /// scope answers it; `DaemonService` sets it on each connection it makes. Runs on this connection's executor.
    public func observePaneNotReady(_ observer: (@Sendable (PaneNotReady) -> Void)?) {
        paneNotReadyObserver = observer
    }

    /// Sets what is told when the reconnect loop's timed retries are spent and it waits for an
    /// event only (a remote machine's header then reads offline, not connecting, HQ #4877 G4).
    /// Runs on this connection's executor, after each failed attempt past the budget.
    public func observeRetriesSpent(_ observer: (@Sendable () -> Void)?) {
        retriesSpentObserver = observer
    }

    /// The event sequence this connection has routed so far, or nil when
    /// not connected. Taken after a command's reply, it is a write barrier:
    /// once `DaemonStore.appliedSequence` reaches it, the store reflects
    /// every event the daemon emitted before that reply (the reply's
    /// `eventBarrier` is at most this). Sequences grow across reconnects.
    public func eventSequence() -> UInt64? { ready?.eventSequence }

    /// Sends one `cmux.protocol/2` resource request (`ResourceRequestEnvelope`)
    /// on the control socket and decodes its `result`; `timeout` replaces the request deadline.
    func resourceRequest<R: Decodable>(_ envelope: @escaping @Sendable (UInt64) -> ResourceRequestEnvelope,
                                       as type: R.Type, timeout: Duration? = nil, requiring capability: String? = nil) async throws -> R {
        await waitOutHandoff()
        guard let ready else { throw DaemonError.notConnected }
        if let capability, !ready.identity.supports(capability) { throw DaemonError.missingCapabilities([capability]) }
        requestStarted()
        defer { requestEnded() }
        let response = try await ready.transport.request(cmd: envelope(0).operation, timeout: timeout ?? configuration.requestTimeout) { id in
            try envelope(id).line()
        }
        return try ResourceRequestEnvelope.decodeResult(R.self, from: response.line)
    }

    /// Delivers an event the connection itself produced, after those routed so far.
    func yieldEvent(_ envelope: DaemonEventEnvelope) {
        continuation.yield(DaemonEventEnvelope(sequence: envelope.sequence, event: envelope.event, sourceID: eventSourceID))
    }

    /// The admitted control session, or nil when not connected.
    var ready: DaemonReadyConnection? {
        guard case .ready(let ready) = phase else { return nil }
        return ready
    }

    static func perform<R: DaemonRequest>(_ request: R, on transport: LineTransport,
                                          timeout: Duration? = defaultRequestTimeout) async throws -> R.Response {
        try await DaemonRequestExecutor(transport: transport).perform(request, timeout: timeout)
    }

    // MARK: - Connect / reconnect

    private func connectOnce() async throws -> DaemonIdentity {
        guard acceptsNewAttempt else {
            throw DaemonError.connectionClosed(reason: "connection is not accepting a new attempt")
        }
        phase = .connecting
        serial += 1
        let serial = serial
        do {
            let endpoint = try await endpointProvider()
            DaemonLaunchTimings.shared.mark("daemon.endpoint_resolved")
            let transport = try LineTransport(path: endpoint.socketPath, bridge: endpoint.bridge)
            DaemonLaunchTimings.shared.mark("daemon.socket_connected")
            let gate = EventGate()
            let continuation = continuation
            let eventSourceID = eventSourceID
            let raw = configuration.role == .pageRelay
            transport.start(
                onEvent: { [weak self] name, line, index in
                    let envelope = DaemonEventEnvelope(
                        sequence: DaemonEventEnvelope.sequence(serial: serial, index: index),
                        event: raw ? DaemonEvent.raw(name: name, line: line) : DaemonEvent.decode(name: name, line: line), sourceID: eventSourceID)
                    if case .sessionState(let item) = envelope.event, item.endsStream {
                        // task-owner: hop onto the actor; a stale serial is ignored there
                        Task { await self?.sessionStreamEvent(item, serial: serial) }
                    }
                    gate.deliver(envelope) { continuation.yield($0) }
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
            phase = .ready(DaemonReadyConnection(transport: transport, serial: serial, identity: identity, userOriginAllowed: userOriginAllowed))
            releaseHandoffHold()
            wake.watch(file: endpoint.socketPath, companions: [endpoint.socketPath + ".websocket.json"])
            healthy.schedule(after: configuration.healthyAfter) { [weak self] in await self?.stayedHealthy(serial: serial) }
            if endpoint.bridge != nil || configuration.localHeartbeat { heartbeat.start(transport, every: configuration.heartbeat, misses: configuration.heartbeatMisses) }
            let connected = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: serial, index: 0),
                                                event: .connected(identity, generationChanged: generationChanged), sourceID: eventSourceID)
            gate.open(first: connected) { continuation.yield($0) }
            // task-owner: one request with the control deadline; a stale serial returns at once
            Task { [weak self] in await self?.openSessionEvents(serial: serial) }
            logger.info("connected to cmux-tui \(identity.session, privacy: .public) pid \(identity.pid) gen \(identity.generation.rawValue, privacy: .public)")
            return identity
        } catch {
            if case .connecting = phase { phase = .waiting }
            throw error
        }
    }

    private var isClosedPhase: Bool { if case .closed = phase { true } else { false } }
    /// Only an idle or waiting connection may start a new endpoint/handshake attempt.
    private var acceptsNewAttempt: Bool {
        switch phase {
        case .idle, .waiting: true
        case .connecting, .ready, .closed: false
        }
    }

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
        continuation.yield(DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: serial, index: DaemonEventEnvelope.lastIndex),
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
        // wakeup-allow: each iteration waits in RetryWake (capped backoff, then events only, or the cap with `keepsTrying`)
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
                    continuation.finish(throwing: error)
                    return
                default:
                    logger.info("cmux-tui reconnect attempt \(self.pacer.failures) failed: \(error.description, privacy: .public)")
                    // A restoring owner keeps the timed budget (`DaemonStartup.ownerIsRestoring`).
                    if DaemonStartup.shared.ownerIsRestoring(error) { pacer.reset() }
                    // A daemon at its connection limit is alive: keep asking, never wait for an event only.
                    if error.isBusyRefusal { pacer.refusedBusy() }
                }
            } catch {
                logger.info("cmux-tui reconnect attempt \(self.pacer.failures) failed: \(String(describing: error), privacy: .public)")
            }
            if pacer.isExhausted {
                logger.info("cmux-tui reconnect: timed retries spent; waiting for the daemon socket or another event")
                // A busy daemon keeps its timed retry: still reconnecting, not offline.
                if pacer.waitsForEventOnly, !Task.isCancelled, !isClosedPhase { retriesSpentObserver?() }
            }
        }
        reconnectTask = nil
    }
}
