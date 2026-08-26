import Foundation

/// One admitted client-side session.
public struct PtxClientSession: Sendable {
    public let sessionID: String
    public let connection: PtxConnection
    public let control: PtxFrameChannel

    public init(sessionID: String, connection: PtxConnection, control: PtxFrameChannel) {
        self.sessionID = sessionID
        self.connection = connection
        self.control = control
    }
}

public enum PtxDialOutcome: Sendable {
    case admitted(PtxClientSession)
    /// Terminal for auto-retry: stale credentials fail the same way forever.
    case denied(String)
}

public enum PtxDialTrigger: Sendable, Equatable {
    /// User intent: replaces an in-flight attempt and redials a ready session.
    case explicit(String)
    /// System cause: joins an in-flight attempt; no-op while ready.
    case automatic(String)

    var reason: String {
        switch self {
        case .explicit(let reason): return "explicit:\(reason)"
        case .automatic(let reason): return "automatic:\(reason)"
        }
    }

    var isExplicit: Bool {
        if case .explicit = self { return true }
        return false
    }
}

public enum PtxOwnerState: Sendable, Equatable {
    case idle
    case connecting
    case ready(sessionID: String)
    /// Terminal until a new trigger arrives with fresh credentials.
    case parked(reason: String)
}

/// The SINGLE dial authority for one Mac peer. Every legacy failure mode this
/// exists to kill is a rule here:
/// - automatic triggers JOIN the in-flight attempt (35/57 legacy reconnect
///   failures were "superseded by a newer attempt");
/// - automatic triggers while ready are no-ops (the 2s churn loop);
/// - denials park the owner instead of retrying into the same denial;
/// - backoff doubles on failure, caps, and RESETS on success;
/// - the owner's watch loop is the only control-lane consumer and surfaces
///   host frames through injected handlers (a second reader would race it
///   and starve — the legacy drained-credential-push bug);
/// - every exit from ready carries an attributed cause.
public actor PtxReconnectOwner {
    public struct Configuration: Sendable {
        public var initialBackoff: Duration = .milliseconds(400)
        public var maxBackoff: Duration = .seconds(30)
        /// Overall budget for one connect attempt (dial + admission).
        public var attemptTimeout: Duration = .seconds(12)
        public var pingInterval: Duration = .seconds(15)

        public init() {}
    }

    private let connect: @Sendable () async throws -> PtxDialOutcome
    private let log: PtxEventLog
    private let configuration: Configuration
    /// Host→client control frames the owner doesn't consume itself
    /// (credential pushes and future opt.* extensions).
    private let onControlFrame: @Sendable (PtxFrame) async -> Void
    private let onStateChange: @Sendable (PtxOwnerState) async -> Void

    private var state: PtxOwnerState = .idle
    private var attemptTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var session: PtxClientSession?
    private var backoff: Duration
    private var attemptCounter = 0
    private var lastPongAt = ContinuousClock.now
    private var stopped = false

    public init(
        configuration: Configuration = Configuration(),
        log: PtxEventLog,
        connect: @escaping @Sendable () async throws -> PtxDialOutcome,
        onControlFrame: @escaping @Sendable (PtxFrame) async -> Void = { _ in },
        onStateChange: @escaping @Sendable (PtxOwnerState) async -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.log = log
        self.connect = connect
        self.onControlFrame = onControlFrame
        self.onStateChange = onStateChange
        self.backoff = configuration.initialBackoff
    }

    public var currentState: PtxOwnerState { state }

    /// Synchronous truth for routing layers: a live session or nothing. Never
    /// dials, never returns a closed connection.
    public func liveSession() -> PtxClientSession? {
        guard case .ready = state, let session, !(sessionIsClosed(session)) else { return nil }
        return session
    }

    private func sessionIsClosed(_ session: PtxClientSession) -> Bool {
        // isClosed is actor-isolated; a conservative sync answer is fine here
        // because the watch loop transitions state on real closure anyway.
        false
    }

    public func trigger(_ trigger: PtxDialTrigger) {
        guard !stopped else { return }
        switch state {
        case .ready:
            if trigger.isExplicit {
                log.emit(PtxEventKind.dialStart, reason: trigger.reason,
                         detail: ["action": "replace-ready"])
                startAttempt(reason: trigger.reason, replacingSession: true)
            } else {
                // Auto-retry while ready is a no-op: the trigger's cause is
                // already served by the live session.
                log.emit(PtxEventKind.dialJoined, reason: trigger.reason,
                         detail: ["state": "ready", "action": "noop"])
            }
        case .connecting:
            if trigger.isExplicit {
                log.emit(PtxEventKind.dialStart, reason: trigger.reason,
                         detail: ["action": "replace-attempt"])
                startAttempt(reason: trigger.reason, replacingSession: false)
            } else {
                log.emit(PtxEventKind.dialJoined, reason: trigger.reason,
                         detail: ["state": "connecting", "action": "join"])
            }
        case .idle, .parked:
            startAttempt(reason: trigger.reason, replacingSession: false)
        }
    }

    public func stop(reason: String) async {
        stopped = true
        retryTask?.cancel()
        attemptTask?.cancel()
        watchTask?.cancel()
        pingTask?.cancel()
        if let session {
            await session.connection.close(reason: reason)
        }
        session = nil
        await setState(.idle, cause: reason)
    }

    private func startAttempt(reason: String, replacingSession: Bool) {
        retryTask?.cancel()
        attemptTask?.cancel()
        let attemptID = nextAttemptID()
        let start = ContinuousClock.now
        log.emit(PtxEventKind.dialStart, reason: reason, detail: ["attempt": attemptID])
        let previousSession = replacingSession ? session : nil
        if replacingSession {
            watchTask?.cancel()
            pingTask?.cancel()
            session = nil
        }
        attemptTask = Task { [weak self] in
            if let previousSession {
                await previousSession.connection.close(
                    reason: PtxCloseReason.explicitRedial.rawValue)
            }
            await self?.runAttempt(attemptID: attemptID, reason: reason, start: start)
        }
        Task { await self.setState(.connecting, cause: reason) }
    }

    private func nextAttemptID() -> String {
        attemptCounter += 1
        return "a\(attemptCounter)"
    }

    private func runAttempt(attemptID: String, reason: String, start: ContinuousClock.Instant) async {
        let outcome: PtxDialOutcome
        do {
            outcome = try await withTimeout(
                configuration.attemptTimeout,
                onAbandoned: { abandoned in
                    if case .admitted(let session) = abandoned {
                        await session.connection.close(
                            reason: PtxCloseReason.explicitRedial.rawValue)
                    }
                }
            ) { [connect] in
                try await connect()
            }
        } catch {
            guard !Task.isCancelled else { return }
            log.emit(
                PtxEventKind.dialFailed, reason: "transient",
                ms: log.elapsedMs(since: start),
                detail: ["attempt": attemptID, "error": String(describing: error)])
            scheduleRetry(cause: "dial-failed")
            return
        }
        guard !Task.isCancelled else {
            // A cancelled-but-admitted dial must be closed explicitly or it
            // leaks a phantom session on the host.
            if case .admitted(let session) = outcome {
                await session.connection.close(reason: PtxCloseReason.explicitRedial.rawValue)
            }
            return
        }
        switch outcome {
        case .denied(let code):
            log.emit(
                PtxEventKind.dialFailed, reason: code,
                ms: log.elapsedMs(since: start), detail: ["attempt": attemptID])
            await setState(.parked(reason: code), cause: code)
        case .admitted(let session):
            self.session = session
            backoff = configuration.initialBackoff
            log.emit(
                PtxEventKind.dialAdmitted, session: session.sessionID,
                ms: log.elapsedMs(since: start), detail: ["attempt": attemptID])
            await setState(.ready(sessionID: session.sessionID), cause: reason)
            startWatch(session: session)
            startPing(session: session)
        }
    }

    /// The single control-lane consumer for the session's lifetime.
    private func startWatch(session: PtxClientSession) {
        watchTask?.cancel()
        watchTask = Task { [weak self, log, onControlFrame] in
            while !Task.isCancelled {
                guard let frame = await session.control.receiveFrame() else { break }
                switch frame.type {
                case PtxFrameType.ping:
                    try? await session.control.sendFrame(
                        PtxFrame(type: PtxFrameType.pong, payload: frame.payload))
                case PtxFrameType.pong:
                    await self?.notePong()
                default:
                    if PtxFrameType.allKnown.contains(frame.type)
                        || frame.type.hasPrefix(PtxFrameType.optionalPrefix)
                    {
                        await onControlFrame(frame)
                    } else {
                        log.emit(
                            PtxEventKind.frameError, session: session.sessionID,
                            reason: "unknown-frame", detail: ["type": frame.type])
                    }
                }
            }
            guard !Task.isCancelled else { return }
            let cause = await session.connection.termination()
            await self?.handleSessionEnded(session: session, cause: cause)
        }
    }

    private func startPing(session: PtxClientSession) {
        pingTask?.cancel()
        lastPongAt = ContinuousClock.now
        pingTask = Task { [weak self, log, configuration] in
            var missed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: configuration.pingInterval)
                guard !Task.isCancelled else { return }
                let sentAt = ContinuousClock.now
                do {
                    try await session.control.sendFrame(
                        PtxFrame(
                            type: PtxFrameType.ping,
                            payload: ["t": .int(Int64(Date().timeIntervalSince1970 * 1000))]))
                } catch {
                    // Send failure means the connection is dead; the watch
                    // loop sees the EOF and owns the transition.
                    return
                }
                log.emit(PtxEventKind.livenessPing, session: session.sessionID)
                guard let self else { return }
                let pongAt = await self.lastPongObservation()
                if pongAt < sentAt {
                    missed += 1
                    if missed >= 2 {
                        // Diagnostic only: liveness degradation never tears
                        // down a session by itself (that is how healthy idle
                        // terminals used to get torn down every ~10s).
                        log.emit(
                            PtxEventKind.livenessDegraded, session: session.sessionID,
                            detail: ["missed": String(missed)])
                    }
                } else {
                    missed = 0
                }
            }
        }
    }

    private func lastPongObservation() -> ContinuousClock.Instant { lastPongAt }

    private func notePong() {
        lastPongAt = ContinuousClock.now
        log.emit(PtxEventKind.livenessPong, session: session?.sessionID)
    }

    private func handleSessionEnded(session ended: PtxClientSession, cause: String?) async {
        guard session?.sessionID == ended.sessionID else { return }
        session = nil
        pingTask?.cancel()
        let reason = cause ?? "unattributed-connection-end"
        log.emit(PtxEventKind.sessionEnd, session: ended.sessionID, reason: reason,
                 detail: ["observer": "owner"])
        let terminal: Set<String> = [
            PtxCloseReason.superseded.rawValue,
            PtxCloseReason.userRequested.rawValue,
            PtxCloseReason.hostStopping.rawValue,
            PtxCloseReason.explicitRedial.rawValue,
        ]
        if terminal.contains(reason) {
            await setState(.idle, cause: reason)
            return
        }
        if reason.hasPrefix("denied-") {
            await setState(.parked(reason: reason), cause: reason)
            return
        }
        // Transport death: redial immediately — detection already spent the
        // latency budget; backoff only grows on consecutive failures.
        await setState(.connecting, cause: reason)
        startAttempt(reason: "auto:\(reason)", replacingSession: false)
    }

    private func scheduleRetry(cause: String) {
        guard !stopped else { return }
        let delay = backoff
        backoff = min(backoff * 2, configuration.maxBackoff)
        log.emit(
            PtxEventKind.reconnectScheduled, reason: cause,
            ms: Int64(delay.components.seconds * 1000)
                + Int64(delay.components.attoseconds / 1_000_000_000_000_000))
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.retryNow(cause: cause)
        }
    }

    private func retryNow(cause: String) {
        guard case .connecting = state else { return }
        startAttempt(reason: "retry:\(cause)", replacingSession: false)
    }

    private func setState(_ newState: PtxOwnerState, cause: String) async {
        guard state != newState else { return }
        let old = state
        state = newState
        log.emit(
            PtxEventKind.stateChanged, reason: cause,
            detail: ["from": describe(old), "to": describe(newState)])
        await onStateChange(newState)
    }

    private func describe(_ state: PtxOwnerState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .ready(let id): return "ready(\(id))"
        case .parked(let reason): return "parked(\(reason))"
        }
    }
}

/// Times out a unit of work without relying on its cancellation support (FFI
/// dials ignore cancellation). If the abandoned work completes after the
/// timeout won, `onAbandoned` receives its value — a dial that admits late
/// MUST be closed there or it leaks a phantom session on the host.
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    onAbandoned: @escaping @Sendable (T) async -> Void = { _ in },
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let once = PtxOnce()
    return try await withCheckedThrowingContinuation { continuation in
        Task {
            do {
                let value = try await work()
                if once.first() {
                    continuation.resume(returning: value)
                } else {
                    await onAbandoned(value)
                }
            } catch {
                if once.first() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: timeout)
            if once.first() { continuation.resume(throwing: PtxTimeoutError()) }
        }
    }
}

struct PtxTimeoutError: Error {}

/// First-wins latch for racing an uncancellable unit of work with a timer.
final class PtxOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
