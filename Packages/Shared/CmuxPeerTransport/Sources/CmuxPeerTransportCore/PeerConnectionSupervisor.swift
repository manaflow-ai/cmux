import Foundation

/// How a dial attempt failed, classified so the supervisor can pick a policy
/// without string matching. Unreachable-class failures arm the retry ladder
/// and mark routes stale; authorization denials are sticky; cancellation is
/// never converted into a retryable failure.
public struct PeerDialFailure: Error, Sendable {
    public enum Class: Sendable, Equatable {
        /// Timeout, refused, no route: retry with backoff, mark route stale.
        case unreachable
        /// Broker/admission said no: sticky, no automatic retry.
        case authorizationDenied
        /// Transient infrastructure trouble (token race, 5xx, cooldown).
        case transient
    }

    public let classification: Class
    public let reason: String
    /// Server-provided floor for the next attempt, when present.
    public let retryAfter: Duration?

    public init(classification: Class, reason: String, retryAfter: Duration? = nil) {
        self.classification = classification
        self.reason = reason
        self.retryAfter = retryAfter
    }
}

/// Why a live session ended.
public enum PeerSessionCloseReason: Sendable, Equatable {
    /// We closed it (sign-out, method change, replacement).
    case local(String)
    /// The peer or the network closed it.
    case remote(String)
    /// Authorization was revoked while connected.
    case revoked
}

/// A live, admitted, data-plane-proven session owned by the supervisor.
public protocol PeerSessionHandle: Sendable {
    /// Resolves when the session ends, with attribution.
    func awaitClose() async -> PeerSessionCloseReason
    /// Idempotent local close.
    func close(reason: String) async
}

/// The single dial path. Implementations await endpoint readiness, dial,
/// admit, and prove data-plane readiness (subscriptions on the new
/// generation) before returning — a returned session IS a usable session.
public protocol PeerSessionEstablishing: Sendable {
    func establish(context: PeerDialContext) async throws -> any PeerSessionHandle
}

public struct PeerDialContext: Sendable {
    public let trigger: PeerDialTrigger
    public let generation: PeerTransportGeneration

    public init(trigger: PeerDialTrigger, generation: PeerTransportGeneration) {
        self.trigger = trigger
        self.generation = generation
    }
}

/// Observable supervisor state. `reconnecting` covers both "attempt in
/// flight" (`attemptInFlight == true`) and "ladder armed, waiting to retry".
public enum PeerConnectionSupervisorState: Sendable, Equatable {
    case idle
    case connecting(PeerDialTrigger)
    case ready
    case reconnecting(PeerDialTrigger)
    case waitingToRetry
    case denied(String)
}

/// One owner per paired peer for dialing, session lifetime, and retry.
///
/// Invariants (each traces to a recorded field failure):
/// - Exactly one attempt task exists at a time. Automatic triggers JOIN it;
///   explicit triggers REPLACE it (supersede storms: 35/57 failures).
/// - Automatic triggers while `ready` are satisfied by the live session
///   (churn: 207 dial failures while a session was up).
/// - The retry ladder lives inside the not-ready states, so entering `ready`
///   structurally cancels it (2s loop that never stopped on success).
/// - Automatic triggers while the scene is inactive park; only the most
///   recent replays once on activation (stale suspended dials).
/// - Authorization denial is sticky until an explicit trigger or an external
///   authorization event (revoked phones must not spin).
public actor PeerConnectionSupervisor {
    private let establisher: any PeerSessionEstablishing
    private let clock: ContinuousClock
    private var backoff: PeerReconnectBackoff
    private let generationCounter = PeerGenerationCounter()
    private let onStateChange: @Sendable (PeerConnectionSupervisorState) -> Void

    private(set) public var state: PeerConnectionSupervisorState = .idle {
        didSet {
            if state != oldValue {
                onStateChange(state)
            }
        }
    }

    private var isSceneActive = true
    private var parkedTrigger: PeerDialTrigger?
    private var attemptTask: Task<Result<Void, PeerDialFailure>, Never>?
    private var attemptTrigger: PeerDialTrigger?
    private var retryTask: Task<Void, Never>?
    private var session: (any PeerSessionHandle)?
    private var sessionWatchTask: Task<Void, Never>?

    public init(
        establisher: any PeerSessionEstablishing,
        backoffProfile: PeerReconnectBackoff.Profile = .foregroundClient,
        backoffSeed: UInt64 = 0x5EED_C0DE,
        clock: ContinuousClock = ContinuousClock(),
        onStateChange: @escaping @Sendable (PeerConnectionSupervisorState) -> Void = { _ in }
    ) {
        self.establisher = establisher
        self.backoff = PeerReconnectBackoff(profile: backoffProfile, seed: backoffSeed)
        self.clock = clock
        self.onStateChange = onStateChange
    }

    // MARK: - Trigger funnel

    /// The only way work enters the supervisor.
    public func note(trigger: PeerDialTrigger) async {
        if trigger == .networkPathChanged || trigger == .foreground {
            backoff.reset()
        }
        guard isSceneActive || trigger.isExplicit else {
            // Park; a dial started while suspended resumes stale and competes
            // with the foreground pass. Only the newest parked trigger
            // replays.
            parkedTrigger = trigger
            return
        }
        switch state {
        case .ready:
            guard trigger.redialsWhileReady else { return }
            await replaceAttempt(trigger: trigger)
        case .connecting, .reconnecting:
            if trigger.isExplicit {
                await replaceAttempt(trigger: trigger)
            }
            // Automatic triggers join the in-flight attempt: nothing to do,
            // the attempt task is already running toward the same outcome.
        case .waitingToRetry:
            // Any wake collapses the wait (level-triggered rebuild).
            cancelRetryTimer()
            startAttempt(trigger: trigger)
        case .idle:
            startAttempt(trigger: trigger)
        case .denied:
            guard trigger.isExplicit else { return }
            startAttempt(trigger: trigger)
        }
    }

    /// External authorization change (new grant, pairing refreshed) clears a
    /// sticky denial.
    public func noteAuthorizationRestored() async {
        if case .denied = state {
            state = .idle
            await note(trigger: .presencePush)
        }
    }

    public func noteScenePhase(active: Bool) async {
        isSceneActive = active
        if active {
            backoff.reset()
            if let parked = parkedTrigger {
                parkedTrigger = nil
                await note(trigger: parked)
            }
        }
    }

    /// Stop everything (sign-out, forget, method disables this transport).
    public func shutDown(reason: String) async {
        parkedTrigger = nil
        cancelRetryTimer()
        attemptTask?.cancel()
        _ = await attemptTask?.value
        attemptTask = nil
        attemptTrigger = nil
        sessionWatchTask?.cancel()
        sessionWatchTask = nil
        if let session {
            await session.close(reason: reason)
        }
        session = nil
        generationCounter.advance()
        state = .idle
    }

    /// Await the in-flight attempt (if any) and report whether the supervisor
    /// is ready. Callers that need a session NOW use this instead of dialing
    /// themselves.
    @discardableResult
    public func awaitSettled() async -> Bool {
        if let attemptTask {
            _ = await attemptTask.value
        }
        return state == .ready
    }

    // MARK: - Attempt lifecycle

    private func startAttempt(trigger: PeerDialTrigger) {
        let generation = generationCounter.advance()
        let wasReady = state == .ready
        state = wasReady || trigger == .backoffExpired
            ? .reconnecting(trigger) : .connecting(trigger)
        attemptTrigger = trigger
        let context = PeerDialContext(trigger: trigger, generation: generation)
        attemptTask = Task { [establisher] in
            do {
                let session = try await establisher.establish(context: context)
                await self.attemptSucceeded(generation: generation, session: session)
                return .success(())
            } catch let failure as PeerDialFailure {
                self.attemptFailed(generation: generation, failure: failure)
                return .failure(failure)
            } catch is CancellationError {
                // Replacement or shutdown owns the state transition.
                return .failure(PeerDialFailure(classification: .transient, reason: "cancelled"))
            } catch {
                let failure = PeerDialFailure(
                    classification: .transient,
                    reason: String(describing: error)
                )
                self.attemptFailed(generation: generation, failure: failure)
                return .failure(failure)
            }
        }
    }

    private func replaceAttempt(trigger: PeerDialTrigger) async {
        cancelRetryTimer()
        attemptTask?.cancel()
        _ = await attemptTask?.value
        attemptTask = nil
        sessionWatchTask?.cancel()
        sessionWatchTask = nil
        if let session {
            await session.close(reason: "replaced by \(trigger)")
        }
        session = nil
        backoff.reset()
        startAttempt(trigger: trigger)
    }

    private func attemptSucceeded(
        generation: PeerTransportGeneration,
        session: any PeerSessionHandle
    ) async {
        guard generationCounter.isCurrent(generation) else {
            // A replacement started while we were establishing; this session
            // lost and must not leak.
            await session.close(reason: "superseded before adoption")
            return
        }
        self.session = session
        backoff.reset()
        state = .ready
        watchSession(session, generation: generation)
    }

    private func attemptFailed(
        generation: PeerTransportGeneration,
        failure: PeerDialFailure
    ) {
        guard generationCounter.isCurrent(generation) else { return }
        attemptTask = nil
        attemptTrigger = nil
        switch failure.classification {
        case .authorizationDenied:
            state = .denied(failure.reason)
        case .unreachable, .transient:
            if let retryAfter = failure.retryAfter {
                backoff.noteServerRetryAfter(retryAfter)
            }
            armRetry()
        }
    }

    private func watchSession(
        _ session: any PeerSessionHandle,
        generation: PeerTransportGeneration
    ) {
        sessionWatchTask = Task {
            let reason = await session.awaitClose()
            await self.sessionClosed(generation: generation, reason: reason)
        }
    }

    private func sessionClosed(
        generation: PeerTransportGeneration,
        reason: PeerSessionCloseReason
    ) async {
        guard generationCounter.isCurrent(generation) else { return }
        session = nil
        attemptTask = nil
        attemptTrigger = nil
        switch reason {
        case .local:
            state = .idle
        case .revoked:
            state = .denied("revoked")
        case .remote:
            armRetry()
        }
    }

    // MARK: - Retry ladder

    private func armRetry() {
        cancelRetryTimer()
        guard isSceneActive else {
            state = .waitingToRetry
            parkedTrigger = .backoffExpired
            return
        }
        let delay = backoff.nextDelay()
        state = .waitingToRetry
        retryTask = Task { [clock] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            await self.note(trigger: .backoffExpired)
        }
    }

    private func cancelRetryTimer() {
        retryTask?.cancel()
        retryTask = nil
    }
}
