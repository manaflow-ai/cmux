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

    public init(
        connection: IrxConnection,
        admit: IrxAdmit,
        control: IrxLaneStream,
        establishedAt: Date
    ) {
        self.connection = connection
        self.admit = admit
        self.control = control
        self.establishedAt = establishedAt
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
        if let session, await !session.connection.isClosed {
            return session
        }
        if let parkedCode, !explicit {
            throw IrxAdmissionDenied(
                code: IrxCloseCode(rawValue: parkedCode) ?? .invalidGrant)
        }
        if explicit {
            parkedCode = nil
            cooldownUntil = nil
            dialTask?.cancel()
            dialTask = nil
        }
        if let dialTask {
            record("dial-joined", ["trigger": trigger])
            return try await dialTask.value
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
        let task = Task<IrxClientSession, any Error> {
            try await self.dialOnce()
        }
        dialTask = task
        do {
            let established = try await task.value
            dialTask = nil
            adopt(established)
            return established
        } catch let denial as IrxAdmissionDenied {
            dialTask = nil
            parkedCode = denial.code.rawValue
            setState(.closed(code: denial.code.rawValue))
            record("dial-denied", ["code": denial.code.rawValue])
            throw denial
        } catch {
            dialTask = nil
            guard !Task.isCancelled else { throw error }
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
        dialTask?.cancel()
        dialTask = nil
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
        session = established
        backoff = config.initialBackoff
        parkedCode = nil
        setState(.ready(session: established.admit.session))
        watchTermination(of: established)
        startKeepalive(of: established)
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
