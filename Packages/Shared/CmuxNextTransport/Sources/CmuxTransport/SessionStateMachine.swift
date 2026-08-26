import Foundation

/// The five session states (contract 4.2). No shadow state anywhere else.
public enum SessionState: Sendable, Equatable {
    case idle
    case connecting
    case ready
    case degraded(DegradeCause)
    case closed(CloseReason)

    public var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }
}

public enum DegradeCause: String, Sendable, Equatable {
    case networkUnavailable = "network-unavailable"
    case pathLost = "path-lost"
    case relayAuthExpired = "relay-auth-expired"
}

/// Every close is attributed: which side, and why (contract 4.4).
public struct CloseReason: Sendable, Equatable {
    public enum Origin: String, Sendable {
        case local, remote, transport
    }

    public var origin: Origin
    public var code: String

    public init(origin: Origin, code: String) {
        self.origin = origin
        self.code = code
    }

    public static let superseded = CloseReason(origin: .remote, code: "superseded")
    public static let userRequested = CloseReason(origin: .local, code: "user-requested")
    public static let modeSwitched = CloseReason(origin: .local, code: "mode-switched")
    public static let admissionDenied = CloseReason(origin: .remote, code: "admission-denied")
    public static let explicitRedial = CloseReason(origin: .local, code: "explicit-redial")
    /// Grace window lapsed with no renewed grant (contract 3.6d).
    public static let grantExpired = CloseReason(origin: .remote, code: "grant-expired")
    /// Harness fault injection killed the session (harness spec 1.2).
    public static let faultInjected = CloseReason(origin: .remote, code: "fault-injected")
}

/// Why a dial is happening. Automatic triggers JOIN an in-flight attempt;
/// explicit user intent REPLACES it (contract 4.3, the supersede-storm killer).
public enum DialIntent: Sendable, Equatable {
    case automatic(trigger: String)  // foreground, push, network change, timer
    case explicit(trigger: String)  // user tapped retry, changed host or mode
}

public struct AttemptID: Sendable, Equatable, Hashable {
    public let raw: UInt64

    public init(raw: UInt64) { self.raw = raw }
}

public enum SessionEvent: Sendable, Equatable {
    case endpointReadyChanged(Bool)
    case dialRequested(DialIntent)
    case dialSucceeded(AttemptID)
    case dialFailed(AttemptID, code: String)
    case connectionDegraded(DegradeCause)
    case connectionRecovered
    case closeRequested(CloseReason)
    case remoteClosed(CloseReason)
}

public enum SessionEffect: Sendable, Equatable {
    case startDial(AttemptID)
    case cancelDial(AttemptID)
    /// The trigger attached itself to the already in-flight attempt.
    case joinDial(AttemptID)
    /// No dial before the endpoint reports ready (contract 2.4).
    case deferDialUntilEndpointReady
    case closeConnection(CloseReason)
    /// The machine is total: undefined (state, event) pairs are recorded and
    /// ignored, never crashed on and never silently swallowed.
    case invalidEventRecorded(String)
}

public struct SessionTransition: Sendable, Equatable {
    public var from: SessionState
    public var event: SessionEvent
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

    public private(set) var state: SessionState = .idle
    public private(set) var endpointReady = false
    public private(set) var transitions: [SessionTransition] = []
    public private(set) var currentAttempt: AttemptID?
    /// A dial was requested before the endpoint was ready (2.4).
    public private(set) var dialDeferred = false
    /// The close was locally REQUESTED (stop, mode switch, denial parking):
    /// terminal. No later trigger may dial a requested-closed machine back
    /// up; a stopped owner that redials is the shutdown-resurrection bug.
    /// Remote closes stay redialable, which is what auto-recovery rides.
    public private(set) var closedTerminally = false

    private var attemptCounter: UInt64 = 0

    public init() {}

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
            if ready, dialDeferred {
                dialDeferred = false
                return beginDial()
            }
            return []

        case .dialRequested(let intent):
            return handleDial(intent)

        case .dialSucceeded(let attempt):
            guard attempt == currentAttempt else {
                return [.invalidEventRecorded("dialSucceeded for stale attempt \(attempt.raw)")]
            }
            currentAttempt = nil
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
            guard !state.isClosed else {
                return [.invalidEventRecorded("closeRequested while already closed")]
            }
            var effects: [SessionEffect] = []
            if let attempt = currentAttempt {
                effects.append(.cancelDial(attempt))
                currentAttempt = nil
            }
            dialDeferred = false
            state = .closed(reason)
            closedTerminally = true
            effects.append(.closeConnection(reason))
            return effects

        case .remoteClosed(let reason):
            guard !state.isClosed, state != .idle else {
                return [.invalidEventRecorded("remoteClosed while \(state)")]
            }
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

        // No dial before the endpoint is ready (contract 2.4). This kills the
        // launch dial race: 286 field failures dialed a dead endpoint.
        guard endpointReady else {
            dialDeferred = true
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
        if !preservingState { state = .connecting }
        return [.startDial(attempt)]
    }
}
