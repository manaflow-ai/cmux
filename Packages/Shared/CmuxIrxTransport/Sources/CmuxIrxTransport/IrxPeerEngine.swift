import CMUXMobileCore
public import Foundation

/// Session state for one Mac peer. Five states, no shadow copies anywhere
/// else; every close carries an attributed reason.
public enum IrxSessionState: Equatable, Sendable {
    case idle
    case connecting
    case ready(session: String)
    case closed(code: String)
}

/// One admitted client session: the connection, its admit receipt, and the
/// control lane the RPC transport rides.
public struct IrxClientSession: Sendable {
    public let connection: IrxConnection
    public let admit: IrxAdmit
    public let control: IrxLaneStream
    public let establishedAt: Date
    /// Monotonic admission time for lifetime diagnostics independent of wall-clock changes.
    public let establishedAtMonotonic: ContinuousClock.Instant

    public init(
        connection: IrxConnection,
        admit: IrxAdmit,
        control: IrxLaneStream,
        establishedAt: Date,
        establishedAtMonotonic: ContinuousClock.Instant = .now
    ) {
        self.connection = connection
        self.admit = admit
        self.control = control
        self.establishedAt = establishedAt
        self.establishedAtMonotonic = establishedAtMonotonic
    }
}

/// THE single reconnect owner for one Mac peer (iOS side). Every trigger -
/// app recovery, foreground, network change, native closure, explicit retry -
/// is an input; automatic triggers JOIN the in-flight dial, explicit intent
/// replaces it. Transport failures retry on a capped backoff that resets on
/// success; denials and supersession park the engine until an explicit
/// trigger. The old stack's parallel dial storms (35 of 57 reconnect failures
/// were "superseded by a newer attempt") cannot happen here by construction.
public actor IrxPeerEngine {
    public struct Config: Sendable {
        public var initialBackoff: Duration
        public var maxBackoff: Duration
        public var keepaliveInterval: Duration
        public var keepaliveDeadline: Duration
        public var foregroundProbeDeadline: Duration
        public var dialDeadline: Duration

        public init(
            initialBackoff: Duration = .milliseconds(400),
            maxBackoff: Duration = .seconds(5),
            keepaliveInterval: Duration = IrxProtocol().keepaliveInterval,
            keepaliveDeadline: Duration = IrxProtocol().keepaliveDeadline,
            foregroundProbeDeadline: Duration = .milliseconds(400),
            dialDeadline: Duration = .seconds(30)
        ) {
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
            self.keepaliveInterval = keepaliveInterval
            self.keepaliveDeadline = keepaliveDeadline
            self.foregroundProbeDeadline = foregroundProbeDeadline
            self.dialDeadline = dialDeadline
        }
    }

    public typealias DialOnce = @Sendable () async throws -> IrxClientSession

    let dialOnce: DialOnce
    let clockNow: @Sendable () -> ContinuousClock.Instant
    let dialSleep: @Sendable (Duration) async throws -> Void
    private let retrySleep: @Sendable (Duration) async throws -> Void
    let config: Config
    private let journal: IrxJournal
    /// Short peer identifier stamped on every journal event so multi-Mac
    /// logs attribute each dial to its target.
    private let label: String
    var session: IrxClientSession?
    private var state: IrxSessionState = .idle
    var dialTask: Task<IrxClientSession, any Error>?
    var dialDeadlineTask: Task<Void, Never>?
    var dialWaiters: [UUID: CheckedContinuation<IrxClientSession, any Error>] = [:]
    /// Monotonic owner token for the dial slot. Cancelling a task does not
    /// guarantee that its underlying transport stops before its waiter
    /// resumes, so completion must prove it still owns the slot before it can
    /// clear or adopt anything.
    var dialGeneration: UInt64 = 0
    var redialTimer: Task<Void, Never>?
    var terminationWatcher: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    private var activityGeneration: UInt64 = 0
    var applicationActive: Bool
    var hasConnectionIntent = false
    private var backoff: Duration
    var parkedCode: String?
    /// Sequential-dial cooldown: after a failure, automatic callers fail fast
    /// until the scheduled redial fires. Without this, an app layer that
    /// retries in a tight loop turns every failure into a dial storm.
    var cooldownUntil: ContinuousClock.Instant?
    var lastDialError: (any Error)?
    private var stateContinuations: [Int: AsyncStream<IrxSessionState>.Continuation] = [:]
    private var closureObservers: [Int: @Sendable (IrxTermination) async -> Void] = [:]
    private var observerCounter = 0

    public init(
        config: Config = Config(),
        journal: IrxJournal,
        label: String = "",
        applicationActive: Bool = true,
        clockNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        dialSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        dialOnce: @escaping DialOnce
    ) {
        self.config = config
        self.journal = journal
        self.label = label
        self.applicationActive = applicationActive
        self.dialOnce = dialOnce
        self.dialSleep = dialSleep
        self.clockNow = clockNow
        self.retrySleep = retrySleep
        backoff = config.initialBackoff
    }

    func record(_ event: String, _ attributes: [String: String] = [:]) {
        var stamped = attributes
        if !label.isEmpty {
            stamped["peer"] = label
        }
        journal.record("engine", event, stamped)
    }

    public var currentState: IrxSessionState { state }

    public func states() -> AsyncStream<IrxSessionState> {
        AsyncStream { continuation in
            observerCounter += 1
            let id = observerCounter
            stateContinuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { _ in
                Task { await self.removeStateContinuation(id) }
            }
        }
    }

    /// Registers for connection-death notifications so the app layer reacts
    /// immediately instead of waiting for its own probes.
    public func observeClosure(
        _ handler: @escaping @Sendable (IrxTermination) async -> Void
    ) {
        observerCounter += 1
        closureObservers[observerCounter] = handler
    }

    /// Proactive warm-up: dial without a caller waiting (app launch, route
    /// learned). Failures follow the normal backoff.
    public func warmUp(trigger: String) {
        hasConnectionIntent = true
        guard applicationActive else { return }
        Task {
            guard self.applicationActive, self.hasConnectionIntent else { return }
            _ = try? await self.ensureSession(trigger: trigger)
        }
    }

    /// Stops probe deadlines and automatic retry work while the app is suspended.
    /// Explicit application requests may still use a granted background execution
    /// window. Their connection intent survives until foreground recovery.
    public func setApplicationActive(_ active: Bool) async {
        guard applicationActive != active else { return }
        applicationActive = active
        activityGeneration &+= 1
        let generation = activityGeneration
        foregroundTask?.cancel()
        foregroundTask = nil
        if !active {
            redialTimer?.cancel()
            redialTimer = nil
            invalidateDial()
            if session == nil { setState(.idle) }
        }
        let connection = session?.connection
        await connection?.setApplicationActive(active)
        guard generation == activityGeneration, applicationActive else { return }
        if hasConnectionIntent { foregroundKick() }
    }

    /// Samples the existing session on a fresh probe deadline after suspension.
    /// An unanswered probe leaves the native connection in place; application
    /// owners repair their streams without replacing the admitted session.
    public func foregroundKick() {
        guard applicationActive, foregroundTask == nil, hasConnectionIntent, parkedCode == nil else { return }
        let generation = activityGeneration
        foregroundTask = Task {
            await self.recoverOnForeground(generation: generation)
            if self.activityGeneration == generation { self.foregroundTask = nil }
        }
    }

    private func recoverOnForeground(generation: UInt64) async {
        let started = clockNow()
        if let previous = session {
            guard foregroundIsCurrent(generation) else { return }
            let probeAnswered: Bool
            if await previous.connection.isConnectionClosed() {
                probeAnswered = false
            } else {
                probeAnswered = await previous.connection.probeLiveness(deadline: config.foregroundProbeDeadline)
            }
            guard foregroundIsCurrent(generation), session?.admit.session == previous.admit.session else { return }
            let nativeClosed = await previous.connection.isConnectionClosed()
            guard foregroundIsCurrent(generation), session?.admit.session == previous.admit.session else { return }
            if !nativeClosed {
                record("foreground-session-retained", ["session": previous.admit.session,
                    "probe_answered": String(probeAnswered),
                    "elapsed": String(describing: started.duration(to: clockNow()))])
                return
            }
            // Use the same reason classification as the native watcher. A
            // terminal peer close must stay parked even if foreground wins
            // the race to observe it.
            await sessionDied(previous, viaKeepalive: false)
        } else {
            guard foregroundIsCurrent(generation) else { return }
            // Foreground can bring a local transport retry forward, while a
            // backend Retry-After floor remains binding across suspension.
            if (lastDialError as? any CmxRetryAfterProviding)?.retryAfterSeconds == nil {
                cooldownUntil = nil
            }
            if let cooldownUntil, clockNow() < cooldownUntil {
                scheduleRemainingCooldown(until: cooldownUntil)
                return
            }
            _ = try? await ensureSession(trigger: "foreground")
        }
        guard foregroundIsCurrent(generation) else { return }
        record("foreground-recovery-finished", ["elapsed": String(describing: started.duration(to: clockNow())),
            "state": Self.describe(state)])
    }

    private func foregroundIsCurrent(_ generation: UInt64) -> Bool {
        applicationActive && activityGeneration == generation && !Task.isCancelled
    }

    /// Event-driven relay race: fresh discovery just revealed a different
    /// home relay for this peer. An admitted session is never touched. An
    /// in-flight dial (aimed at the stale relay, where it
    /// would sit out a silent black-hole timeout) is cancelled and replaced
    /// immediately; a pending backoff redial is pulled forward. Parked
    /// denials stay parked: authorization state is not a routing question.
    public func relayHintChanged(trigger: String) {
        if case .ready = state { return }
        if parkedCode != nil { return }
        guard dialTask != nil || redialTimer != nil || cooldownUntil != nil else {
            return
        }
        if let cooldownUntil,
           clockNow() < cooldownUntil,
           (lastDialError as? any CmxRetryAfterProviding)?.retryAfterSeconds != nil {
            record("hint-race-redial-suppressed", ["reason": "retry-after"])
            return
        }
        record("hint-race-redial", ["trigger": trigger])
        invalidateDial()
        redialTimer?.cancel()
        redialTimer = nil
        cooldownUntil = nil
        backoff = config.initialBackoff
        guard applicationActive else { return }
        Task {
            guard self.applicationActive, self.hasConnectionIntent else { return }
            _ = try? await self.ensureSession(trigger: trigger)
        }
    }

    public func currentSession() async -> IrxClientSession? {
        if let session, await !session.connection.isConnectionClosed() {
            return session
        }
        return nil
    }

    /// Retires one exact admitted session for a planned owner handoff.
    ///
    /// The caller remains responsible for closing the matching connection
    /// after this method returns. Clearing the engine first prevents the
    /// termination watcher or keepalive callback from scheduling an automatic
    /// replacement for a connection that the client intentionally retired.
    @discardableResult
    public func retire(
        connection: IrxConnection,
        code: IrxCloseCode = .explicitRedial
    ) -> Bool {
        guard let current = session, current.connection === connection else {
            return false
        }
        session = nil
        terminationWatcher?.cancel()
        terminationWatcher = nil
        redialTimer?.cancel()
        redialTimer = nil
        invalidateDial()
        cooldownUntil = nil
        lastDialError = nil
        parkedCode = nil
        backoff = config.initialBackoff
        record(
            "session-retired",
            [
                "session": current.admit.session,
                "code": code.rawValue,
            ]
        )
        setState(.closed(code: code.rawValue))
        return true
    }

    /// Tears the session down deliberately (sign-out, mode switch).
    public func stop(code: IrxCloseCode = .userRequested) async {
        hasConnectionIntent = false
        activityGeneration &+= 1
        foregroundTask?.cancel()
        foregroundTask = nil
        redialTimer?.cancel()
        redialTimer = nil
        invalidateDial()
        terminationWatcher?.cancel()
        terminationWatcher = nil
        if let session {
            await session.connection.close(code: code, origin: .local)
        }
        session = nil
        parkedCode = code == .userRequested ? code.rawValue : parkedCode
        setState(.closed(code: code.rawValue))
    }

    func adopt(_ established: IrxClientSession) {
        let previous = session
        session = established
        backoff = config.initialBackoff
        parkedCode = nil
        setState(.ready(session: established.admit.session))
        watchTermination(of: established)
        startKeepalive(of: established)
        // Replacement is make-before-break. The new session is published and
        // keepalive-armed before the old connection is closed, so a planned
        // RPC/client handoff cannot create a peer-visible outage. The old
        // termination watcher is already cancelled by watchTermination.
        if let previous,
           previous.admit.session != established.admit.session {
            Task {
                await previous.connection.close(
                    code: .explicitRedial,
                    origin: .local
                )
            }
        }
    }

    private func startKeepalive(of established: IrxClientSession) {
        Task {
            guard self.session?.admit.session == established.admit.session else { return }
            await established.connection.setApplicationActive(self.applicationActive)
            guard self.session?.admit.session == established.admit.session else { return }
            try? await established.connection.startClientKeepalive(
                interval: config.keepaliveInterval, deadline: config.keepaliveDeadline
            ) { [weak self] in
                await self?.sessionDied(established, viaKeepalive: true)
            }
        }
    }

    private func watchTermination(of established: IrxClientSession) {
        terminationWatcher?.cancel()
        terminationWatcher = Task { [weak self] in
            _ = await established.connection.termination()
            guard !Task.isCancelled else { return }
            await self?.sessionDied(established, viaKeepalive: false)
        }
    }

    private func sessionDied(_ died: IrxClientSession, viaKeepalive: Bool) async {
        guard session?.admit.session == died.admit.session else { return }
        session = nil
        let termination = await died.connection.termination()
        record(
            "session-ended",
            [
                "session": died.admit.session,
                "code": termination.code,
                "origin": termination.origin.rawValue,
                "via": viaKeepalive ? "keepalive" : "termination-watch",
                "lifetime_s": String(Int(Date().timeIntervalSince(died.establishedAt))),
            ]
        )
        setState(.closed(code: termination.code))
        for observer in closureObservers.values {
            await observer(termination)
        }
        let terminal =
            IrxCloseCode(rawValue: termination.code).map {
                IrxCloseCode.terminalForAutoRedial.contains($0)
            } ?? false
        if terminal {
            parkedCode = termination.code
            record("auto-redial-suppressed", ["code": termination.code])
            return
        }
        // Auto-recovery: the first redial after a death is immediate; only
        // consecutive failures back off.
        guard applicationActive else {
            record("auto-redial-deferred", ["reason": "background"])
            return
        }
        record("auto-redial", ["code": termination.code])
        Task {
            guard self.applicationActive, self.hasConnectionIntent else { return }
            _ = try? await self.ensureSession(trigger: "connection-ended")
        }
    }

    /// Capped, cancellable backoff. The woken redial is an ordinary automatic
    /// trigger that joins whatever else happened since.
    func scheduleRedial(error: any Error) {
        let retryAfterSeconds = (error as? any CmxRetryAfterProviding)?
            .retryAfterSeconds
        let serverFloor = Duration.seconds(Int64(max(0, retryAfterSeconds ?? 0)))
        let delay = max(backoff, serverFloor)
        backoff = min(backoff * 2, config.maxBackoff)
        let deadline = clockNow().advanced(by: delay)
        cooldownUntil = deadline
        scheduleRemainingCooldown(until: deadline)
        record("redial-scheduled", [
            "delay": String(describing: delay),
            "server_floor_s": retryAfterSeconds.map(String.init) ?? "-",
        ])
    }

    private func scheduleRemainingCooldown(until deadline: ContinuousClock.Instant) {
        redialTimer?.cancel()
        redialTimer = nil
        guard applicationActive, hasConnectionIntent else { return }
        let delay = max(.zero, clockNow().duration(to: deadline))
        redialTimer = Task { [weak self, retrySleep] in
            do { try await retrySleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.clearCooldownAndRedial()
        }
    }

    private func clearCooldownAndRedial() async {
        guard applicationActive, hasConnectionIntent, !Task.isCancelled else { return }
        redialTimer = nil
        cooldownUntil = nil
        _ = try? await ensureSession(trigger: "backoff")
    }

    func setState(_ next: IrxSessionState) {
        guard next != state else { return }
        record(
            "state",
            ["from": Self.describe(state), "to": Self.describe(next)]
        )
        state = next
        for continuation in stateContinuations.values {
            continuation.yield(next)
        }
    }

    private func removeStateContinuation(_ id: Int) {
        stateContinuations[id] = nil
    }

    private static func describe(_ state: IrxSessionState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .ready(let session): return "ready(\(session))"
        case .closed(let code): return "closed(\(code))"
        }
    }
}
