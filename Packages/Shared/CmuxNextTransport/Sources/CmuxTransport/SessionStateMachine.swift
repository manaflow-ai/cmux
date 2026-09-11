import Foundation

/// The five session states (contract 4.2). No shadow state anywhere else.
public enum SessionState: Sendable, Equatable {
    /// No dial or admitted connection exists.
    case idle
    /// A dial is in flight or deferred until endpoint readiness.
    case connecting
    /// A connection has completed admission and can carry application traffic.
    case ready
    /// A connection has degraded and recovery may be attempted.
    case degraded(DegradeCause)
    /// The session ended with an attributed cause.
    case closed(CloseReason)

    /// Whether this value carries a close reason, independent of terminal-stop policy.
    public var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }
}

/// Recoverable causes of degraded session health.
public enum DegradeCause: String, Sendable, Equatable {
    /// The endpoint currently has no usable network.
    case networkUnavailable = "network-unavailable"
    /// The path carrying the admitted connection was lost.
    case pathLost = "path-lost"
    /// Relay admission credentials expired while the session was active.
    case relayAuthExpired = "relay-auth-expired"
}

/// Every close is attributed: which side, and why (contract 4.4).
public struct CloseReason: Sendable, Equatable {
    /// Component responsible for ending the session.
    public enum Origin: String, Sendable {
        /// Local application explicitly ended the session.
        case local
        /// The remote peer supplied the close reason.
        case remote
        /// The underlying transport ended the connection.
        case transport
    }

    /// Attribution of the close, distinct from its stable reason code.
    public var origin: Origin
    /// Stable protocol or application reason, not a rendered diagnostic.
    public var code: String

    /// Records an attributed close for state transitions and diagnostics.
    /// - Parameters:
    ///   - origin: Component responsible for ending the session.
    ///   - code: Stable reason code.
    public init(origin: Origin, code: String) {
        self.origin = origin
        self.code = code
    }

    /// Another session replaced this peer's previous admitted session.
    public static let superseded = CloseReason(origin: .remote, code: "superseded")
    /// The user explicitly stopped the local session.
    public static let userRequested = CloseReason(origin: .local, code: "user-requested")
    /// A local transport-mode switch ended this session.
    public static let modeSwitched = CloseReason(origin: .local, code: "mode-switched")
    /// Admission was refused and the owner must park rather than retry.
    public static let admissionDenied = CloseReason(origin: .remote, code: "admission-denied")
    /// The peer did not complete the hello handshake before the deadline;
    /// this is a transport loss and the owner should retry automatically.
    public static let handshakeTimeout = CloseReason(origin: .remote, code: "handshake-timeout")
    /// Explicit retry intent replaced the current connection.
    public static let explicitRedial = CloseReason(origin: .local, code: "explicit-redial")
    /// Grace window lapsed with no renewed grant (contract 3.6d).
    public static let grantExpired = CloseReason(origin: .remote, code: "grant-expired")
    /// Harness fault injection killed the session (harness spec 1.2).
    public static let faultInjected = CloseReason(origin: .remote, code: "fault-injected")
}

/// Why a dial is happening. Automatic triggers JOIN an in-flight attempt;
/// explicit user intent REPLACES it (contract 4.3, the supersede-storm killer).
public enum DialIntent: Sendable, Equatable {
    /// Ambient recovery intent that joins an in-flight attempt or leaves ready state alone.
    case automatic(trigger: String)  // foreground, push, network change, timer
    /// User intent that replaces existing work once endpoint readiness permits it.
    case explicit(trigger: String)  // user tapped retry, changed host or mode
}

/// Monotonic identity of one dial attempt within a state-machine lifetime.
public struct AttemptID: Sendable, Equatable, Hashable {
    /// Attempt counter assigned by the owning state machine.
    public let raw: UInt64

    /// Wraps an attempt counter without allocating a new attempt.
    /// - Parameter raw: Counter whose scope is one state-machine lifetime.
    public init(raw: UInt64) { self.raw = raw }
}

/// Identifies the connection generation that owns a remote-close event.
/// Generations change as soon as a new dial replaces an existing connection,
/// so a late close from the previous connection cannot tear down its successor.
public struct ConnectionGeneration: Sendable, Equatable, Hashable {
    /// Generation counter assigned when the owning attempt starts.
    public let raw: UInt64

    /// Wraps the generation associated with a connection's owning attempt.
    /// - Parameter raw: Counter scoped to the same state machine as its attempt.
    public init(raw: UInt64) { self.raw = raw }
}

/// Inputs to the state machine, including generation-fenced asynchronous results.
public enum SessionEvent: Sendable, Equatable {
    /// Endpoint readiness changed; becoming ready may release one deferred dial.
    case endpointReadyChanged(Bool)
    /// A caller requested automatic recovery or explicit replacement.
    case dialRequested(DialIntent)
    /// The identified attempt completed admission successfully.
    case dialSucceeded(AttemptID)
    /// The identified attempt failed with a stable diagnostic code.
    case dialFailed(AttemptID, code: String)
    /// Current connection health degraded for a recoverable reason.
    case connectionDegraded(DegradeCause)
    /// A degraded connection became healthy without replacement.
    case connectionRecovered
    /// A local stop requests terminal closure of this owner.
    case closeRequested(CloseReason)
    /// The identified connection generation ended remotely.
    case remoteClosed(ConnectionGeneration, CloseReason)
}

/// Ordered side effects for the reconnect runtime to perform after a transition.
public enum SessionEffect: Sendable, Equatable {
    /// Begin exactly one attempt with the assigned identity.
    case startDial(AttemptID)
    /// Cancel the identified attempt and discard any late result it produces.
    case cancelDial(AttemptID)
    /// The trigger attached itself to the already in-flight attempt.
    case joinDial(AttemptID)
    /// No dial before the endpoint reports ready (contract 2.4).
    case deferDialUntilEndpointReady
    /// Close the currently owned connection with the supplied cause.
    case closeConnection(CloseReason)
    /// The machine is total: undefined (state, event) pairs are recorded and
    /// ignored, never crashed on and never silently swallowed.
    case invalidEventRecorded(String)
}

/// One bounded-history entry, including events that did not change state.
public struct SessionTransition: Sendable, Equatable {
    /// State before the event was handled.
    public var from: SessionState
    /// Event that produced this history entry.
    public var event: SessionEvent
    /// State after handling the event.
    public var to: SessionState
}

/// Pure, synchronous, deterministic session state machine. All I/O lives in
/// the runtime that owns it; this is the single reconnect owner's brain
/// (contract 4.2, 4.3, 4.5, 4.6 at the logic level). Tests drive the full
/// (state x event) matrix.
public struct SessionStateMachine: Sendable {
    /// Bound on the retained transition history: the log exists for
    /// attribution (4.4, 8.1), not archival. A long-lived owner riding weeks
    /// of backoff churn would otherwise grow it without bound; the most
    /// recent window is what every consumer (soak assertions, debug dumps)
    /// actually reads.
    public static let transitionLogLimit = 256

    /// Authoritative session state, initially idle.
    public private(set) var state: SessionState = .idle
    /// Last endpoint readiness observation; new work is gated on true.
    public private(set) var endpointReady = false
    /// Most recent transitions, capped by ``transitionLogLimit``.
    public private(set) var transitions: [SessionTransition] = []
    /// Only attempt currently permitted to publish success or failure.
    public private(set) var currentAttempt: AttemptID?
    /// The generation currently allowed to report a remote close. It is
    /// advanced when a replacement dial starts, before that dial succeeds.
    public private(set) var activeConnectionGeneration: ConnectionGeneration?
    /// A dial was requested before the endpoint was ready (2.4).
    public var dialDeferred: Bool { deferredDialIntent != nil }
    /// The close was locally REQUESTED (stop, mode switch, denial parking):
    /// terminal. No later trigger may dial a requested-closed machine back
    /// up; a stopped owner that redials is the shutdown-resurrection bug.
    /// Remote closes stay redialable, which is what auto-recovery rides.
    public private(set) var closedTerminally = false

    private var attemptCounter: UInt64 = 0
    private var deferredDialIntent: DialIntent?

    /// Creates an idle state machine with no ready endpoint or active attempt.
    public init() {}

    /// Applies one event synchronously and records the resulting transition.
    ///
    /// ```swift
    /// var machine = SessionStateMachine()
    /// _ = machine.handle(.endpointReadyChanged(true))
    /// let effects = machine.handle(.dialRequested(.automatic(trigger: "foreground")))
    /// ```
    ///
    /// - Parameter event: The next observed lifecycle event.
    /// - Returns: Ordered effects for the owner; no I/O occurs inside the state machine.
    public mutating func handle(_ event: SessionEvent) -> [SessionEffect] {
        let from = state
        let effects = apply(event)
        transitions.append(SessionTransition(from: from, event: event, to: state))
        if transitions.count > Self.transitionLogLimit {
            transitions.removeFirst(transitions.count - Self.transitionLogLimit)
        }
        return effects
    }

    private mutating func apply(_ event: SessionEvent) -> [SessionEffect] {
        switch event {
        case .endpointReadyChanged(let ready):
            endpointReady = ready
            if ready, let intent = deferredDialIntent {
                deferredDialIntent = nil
                // Readiness can change while a session or attempt is still
                // live. Replay the intent through the normal ownership path,
                // including joins and explicit connection retirement.
                return handleDial(intent)
            }
            return []

        case .dialRequested(let intent):
            return handleDial(intent)

        case .dialSucceeded(let attempt):
            guard attempt == currentAttempt else {
                return [.invalidEventRecorded("dialSucceeded for stale attempt \(attempt.raw)")]
            }
            currentAttempt = nil
            activeConnectionGeneration = ConnectionGeneration(raw: attempt.raw)
            switch state {
            case .connecting, .degraded:
                state = .ready
                return []
            default:
                return [.invalidEventRecorded("dialSucceeded while \(state)")]
            }

        case .dialFailed(let attempt, _):
            guard attempt == currentAttempt else {
                return [.invalidEventRecorded("dialFailed for stale attempt \(attempt.raw)")]
            }
            currentAttempt = nil
            if activeConnectionGeneration?.raw == attempt.raw {
                activeConnectionGeneration = nil
            }
            switch state {
            case .connecting:
                // The reconnect owner schedules the next dial with backoff
                // (4.6); the machine just reports the truth.
                state = .idle
                return []
            case .degraded:
                return []  // stay degraded; recovery retries continue
            default:
                return [.invalidEventRecorded("dialFailed while \(state)")]
            }

        case .connectionDegraded(let cause):
            guard state == .ready else {
                return [.invalidEventRecorded("connectionDegraded while \(state)")]
            }
            state = .degraded(cause)
            return []

        case .connectionRecovered:
            guard case .degraded = state else {
                return [.invalidEventRecorded("connectionRecovered while \(state)")]
            }
            state = .ready
            return []

        case .closeRequested(let reason):
            guard !closedTerminally else {
                return [.invalidEventRecorded("closeRequested while already closed")]
            }
            var effects: [SessionEffect] = []
            if let attempt = currentAttempt {
                effects.append(.cancelDial(attempt))
                currentAttempt = nil
            }
            deferredDialIntent = nil
            activeConnectionGeneration = nil
            state = .closed(reason)
            closedTerminally = true
            effects.append(.closeConnection(reason))
            return effects

        case .remoteClosed(let generation, let reason):
            guard activeConnectionGeneration == generation else {
                return [.invalidEventRecorded(
                    "remoteClosed for stale generation \(generation.raw)")]
            }
            guard !state.isClosed, state != .idle else {
                return [.invalidEventRecorded("remoteClosed while \(state)")]
            }
            activeConnectionGeneration = nil
            if let attempt = currentAttempt {
                currentAttempt = nil
                state = .closed(reason)
                return [.cancelDial(attempt)]
            }
            state = .closed(reason)
            return []
        }
    }

    private mutating func handleDial(_ intent: DialIntent) -> [SessionEffect] {
        // A requested close is terminal: the stopped owner must never dial
        // again, no matter what trigger (backoff wake, foreground, user tap)
        // arrives afterwards. Recovery from here means building a new owner.
        guard !closedTerminally else {
            return [.invalidEventRecorded("dialRequested after terminal close")]
        }

        // Endpoint readiness gates new work, not ownership of a session or
        // attempt that already exists. Ambient triggers must remain no-ops
        // or joins even during a readiness flap.
        if case .automatic = intent {
            if state == .ready { return [] }
            if let attempt = currentAttempt { return [.joinDial(attempt)] }
        }

        // No dial before the endpoint is ready (contract 2.4). This kills the
        // launch dial race: 286 field failures dialed a dead endpoint.
        guard endpointReady else {
            if case .explicit = intent {
                deferredDialIntent = intent
            } else if deferredDialIntent == nil {
                deferredDialIntent = intent
            }
            if state == .idle || state.isClosed { state = .connecting }
            return [.deferDialUntilEndpointReady]
        }

        switch state {
        case .idle, .closed:
            return beginDial()

        case .connecting:
            guard let attempt = currentAttempt else {
                return beginDial()
            }
            switch intent {
            case .automatic:
                // Automatic triggers join; they never race the in-flight
                // attempt (4.3).
                return [.joinDial(attempt)]
            case .explicit:
                let effects: [SessionEffect] = [.cancelDial(attempt)]
                return effects + beginDial()
            }

        case .ready:
            switch intent {
            case .automatic:
                // Already connected: retry loops stop on success (4.6). The
                // field logs showed a 2s dial loop churning against a live
                // session; this is the clause that forbids it.
                return []
            case .explicit:
                state = .connecting
                return [.closeConnection(.explicitRedial)] + beginDial()
            }

        case .degraded:
            if let attempt = currentAttempt {
                switch intent {
                case .automatic: return [.joinDial(attempt)]
                case .explicit:
                    let effects: [SessionEffect] = [.cancelDial(attempt)]
                    return effects + beginDial(preservingState: true)
                }
            }
            return beginDial(preservingState: true)
        }
    }

    private mutating func beginDial(preservingState: Bool = false) -> [SessionEffect] {
        attemptCounter += 1
        let attempt = AttemptID(raw: attemptCounter)
        currentAttempt = attempt
        // Fence the previous connection immediately. A late termination event
        // from that connection must not close the replacement while it dials.
        activeConnectionGeneration = ConnectionGeneration(raw: attempt.raw)
        if !preservingState { state = .connecting }
        return [.startDial(attempt)]
    }
}
