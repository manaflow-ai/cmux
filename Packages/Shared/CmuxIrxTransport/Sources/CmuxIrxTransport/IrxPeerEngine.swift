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
    /// Monotonic counterpart used for liveness decisions. Wall-clock time is
    /// retained for diagnostics only because clock rollback must not suppress
    /// a foreground zombie replacement.
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
/// app recovery, foreground, network change, keepalive death, explicit retry -
/// is an input; automatic triggers JOIN the in-flight dial, explicit intent
/// replaces it. Transport failures retry on a capped backoff that resets on
/// success; denials and supersession park the engine until an explicit
/// trigger. The old stack's parallel dial storms (35 of 57 reconnect failures
/// were "superseded by a newer attempt") cannot happen here by construction.
public actor IrxPeerEngine {
    public struct Config: Sendable {
        public var initialBackoff: Duration
        public var maxBackoff: Duration

        public init(
            initialBackoff: Duration = .milliseconds(400),
            maxBackoff: Duration = .seconds(5)
        ) {
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
        }
    }

    public typealias DialOnce = @Sendable () async throws -> IrxClientSession

    private let dialOnce: DialOnce
    private let config: Config
    private let journal: IrxJournal
    /// Short peer identifier stamped on every journal event so multi-Mac
    /// logs attribute each dial to its target.
    private let label: String
    private var session: IrxClientSession?
    private var state: IrxSessionState = .idle
    private var dialTask: Task<IrxClientSession, any Error>?
    /// Monotonic owner token for the dial slot. Cancelling a task does not
    /// guarantee that its underlying transport stops before its waiter
    /// resumes, so completion must prove it still owns the slot before it can
    /// clear or adopt anything.
    private var dialGeneration: UInt64 = 0
    private var redialTimer: Task<Void, Never>?
    private var terminationWatcher: Task<Void, Never>?
    private var backoff: Duration
    private var parkedCode: String?
    /// Sequential-dial cooldown: after a failure, automatic callers fail fast
    /// until the scheduled redial fires. Without this, an app layer that
    /// retries in a tight loop turns every failure into a dial storm.
    private var cooldownUntil: ContinuousClock.Instant?
    private var lastDialError: (any Error)?
    private var stateContinuations: [Int: AsyncStream<IrxSessionState>.Continuation] = [:]
    private var closureObservers: [Int: @Sendable (IrxTermination) async -> Void] = [:]
    private var observerCounter = 0

    public init(
        config: Config = Config(),
        journal: IrxJournal,
        label: String = "",
        dialOnce: @escaping DialOnce
    ) {
        self.config = config
        self.journal = journal
        self.label = label
        self.dialOnce = dialOnce
        backoff = config.initialBackoff
    }

    private func record(_ event: String, _ attributes: [String: String] = [:]) {
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

    /// Returns the live session, joining an in-flight dial or starting one.
    /// This is the ONLY dial path; `explicit` overrides a parked denial and
    /// replaces any in-flight attempt.
    public func ensureSession(explicit: Bool = false, trigger: String) async throws -> IrxClientSession {
        if let session, await !session.connection.isClosed, !explicit {
            return session
        }
        if let parkedCode, !explicit {
            throw IrxAdmissionDenied(
                code: IrxCloseCode(rawValue: parkedCode) ?? .invalidGrant)
        }
        if explicit {
            // An explicit replacement invalidates the old session before the
            // new dial starts. Keeping it here after a failed replacement
            // makes currentSession() return a zombie and suppresses every
            // subsequent automatic dial.
            let previous = session
            session = nil
            terminationWatcher?.cancel()
            terminationWatcher = nil
            parkedCode = nil
            cooldownUntil = nil
            invalidateDial()
            if let previous {
                Task {
                    await previous.connection.close(
                        code: .explicitRedial,
                        origin: .local
                    )
                }
            }
        }
        if let dialTask {
            record("dial-joined", ["trigger": trigger])
            let generation = dialGeneration
            let joined = try await dialTask.value
            guard dialGeneration == generation else {
                await joined.connection.close(code: .explicitRedial, origin: .local)
                throw CancellationError()
            }
            return joined
        }
        if !explicit, let cooldownUntil, ContinuousClock.now < cooldownUntil {
            // The scheduled redial owns the next attempt; fail fast instead
            // of stacking another dial on top of it.
            throw lastDialError ?? IrxConnectionError.closed(nil)
        }
        redialTimer?.cancel()
        redialTimer = nil
        setState(.connecting)
        record("dial-started", ["trigger": trigger])
        dialGeneration &+= 1
        let generation = dialGeneration
        let task = Task<IrxClientSession, any Error> {
            try await self.dialOnce()
        }
        dialTask = task
        do {
            let established = try await task.value
            guard dialGeneration == generation else {
                await established.connection.close(
                    code: .explicitRedial, origin: .local)
                throw CancellationError()
            }
            dialTask = nil
            adopt(established)
            return established
        } catch let denial as IrxAdmissionDenied {
            guard dialGeneration == generation else { throw denial }
            dialTask = nil
            parkedCode = denial.code.rawValue
            setState(.closed(code: denial.code.rawValue))
            record("dial-denied", ["code": denial.code.rawValue])
            throw denial
        } catch {
            guard dialGeneration == generation else { throw error }
            dialTask = nil
            // Cancellation is always owner-driven (stop(), an explicit
            // replacement, or a hint-race redial); the canceller owns the
            // next state, so no failure bookkeeping and no redial schedule.
            if error is CancellationError || Task.isCancelled { throw error }
            lastDialError = error
            setState(.closed(code: "dial-failed"))
            record(
                "dial-failed",
                ["trigger": trigger, "error": String(describing: error)]
            )
            scheduleRedial()
            throw error
        }
    }

    /// Proactive warm-up: dial without a caller waiting (app launch, route
    /// learned). Failures follow the normal backoff.
    public func warmUp(trigger: String) {
        Task { _ = try? await self.ensureSession(trigger: trigger) }
    }

    /// Foreground resume: a session that has not proven liveness recently is
    /// treated as a zombie (a suspension can kill the QUIC connection without
    /// isClosed flipping) and replaced IMMEDIATELY — close + explicit redial —
    /// instead of waiting out keepalive strike detection. Fresh sessions and
    /// no-session states fall through to a normal warm-up.
    public func foregroundKick(staleAfter: Duration = .seconds(15)) {
        Task {
            if let session = await self.currentSessionForKick() {
                // Liveness evidence is a recent pong OR a recent admission: a
                // just-established session has no pong yet and must not be
                // executed as a zombie while its first keepalive is in flight
                // (that exact race produced the foreground redial storm).
                let now = ContinuousClock.now
                let pongAge = (await session.connection.lastPongAt).map { now - $0 }
                let sessionAge = session.establishedAtMonotonic.duration(to: now)
                let liveness = pongAge.map { min($0, sessionAge) } ?? sessionAge
                if liveness > staleAfter {
                    self.record("foreground-stale-redial", [:])
                    _ = try? await self.ensureSession(explicit: true, trigger: "foreground-stale")
                    return
                }
            }
            _ = try? await self.ensureSession(trigger: "foreground")
        }
    }

    private func currentSessionForKick() -> IrxClientSession? {
        session
    }

    /// Event-driven relay race: fresh discovery just revealed a different
    /// home relay for this peer. An admitted session passing keepalives is
    /// never touched. An in-flight dial (aimed at the stale relay, where it
    /// would sit out a silent black-hole timeout) is cancelled and replaced
    /// immediately; a pending backoff redial is pulled forward. Parked
    /// denials stay parked: authorization state is not a routing question.
    public func relayHintChanged(trigger: String) {
        if case .ready = state { return }
        if parkedCode != nil { return }
        guard dialTask != nil || redialTimer != nil || cooldownUntil != nil else {
            return
        }
        record("hint-race-redial", ["trigger": trigger])
        invalidateDial()
        redialTimer?.cancel()
        redialTimer = nil
        cooldownUntil = nil
        backoff = config.initialBackoff
        Task { _ = try? await self.ensureSession(trigger: trigger) }
    }

    public func currentSession() async -> IrxClientSession? {
        if let session, await !session.connection.isClosed {
            return session
        }
        return nil
    }

    /// Tears the session down deliberately (sign-out, mode switch).
    public func stop(code: IrxCloseCode = .userRequested) async {
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

    private func adopt(_ established: IrxClientSession) {
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
            try? await established.connection.startClientKeepalive { [weak self] in
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
        record("auto-redial", ["code": termination.code])
        Task { _ = try? await self.ensureSession(trigger: "connection-ended") }
    }

    /// Capped, cancellable backoff. The woken redial is an ordinary automatic
    /// trigger that joins whatever else happened since.
    private func scheduleRedial() {
        let delay = backoff
        backoff = min(backoff * 2, config.maxBackoff)
        cooldownUntil = ContinuousClock.now.advanced(by: delay)
        redialTimer?.cancel()
        redialTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.clearCooldownAndRedial()
        }
        record("redial-scheduled", ["delay": String(describing: delay)])
    }

    private func clearCooldownAndRedial() async {
        cooldownUntil = nil
        _ = try? await ensureSession(trigger: "backoff")
    }

    private func setState(_ next: IrxSessionState) {
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

    private func invalidateDial() {
        dialGeneration &+= 1
        dialTask?.cancel()
        dialTask = nil
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
