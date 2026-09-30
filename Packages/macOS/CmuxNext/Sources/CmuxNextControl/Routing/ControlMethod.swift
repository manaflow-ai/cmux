public import CmuxNextSettings

/// One control-socket method and the lane it runs on
/// (plans/cmux-next/architecture.md section 5a).
///
/// - `snapshot`: read-only. Runs on the connection's task, off the main
///   actor, against the immutable ``ControlSnapshot`` current when the
///   request arrived. Never touches `@MainActor` state and never waits.
/// - `mainActor`: mutating. Its body runs on the main actor through the
///   bounded ``MainActorWorkQueue`` (per-connection FIFO, frame-budgeted,
///   fails fast with `busy`). The body must be synchronous and short: it
///   applies optimistic local state and returns a value, or returns
///   ``ControlReply/followUp(_:)`` whose async work (a daemon command)
///   then runs off the main actor under the request's deadline.
/// - `async`: runs off the main actor with the request's deadline, for
///   methods that talk to another process or actor (settings file, daemon)
///   without main-actor state.
///
/// Compat handlers (`CmuxNextControl/Compat/`) and the App register methods
/// with ``ControlRouter/register(_:)``.
public struct ControlMethod: Sendable {
    public enum Lane: String, Sendable {
        case snapshot
        case mainActor = "main_actor"
        case async
    }

    enum Body: Sendable {
        case snapshot(@Sendable (ControlCall) throws -> JSONValue)
        case mainActor(@MainActor @Sendable (ControlCall) throws -> ControlReply)
        case async(@Sendable (ControlCall) async throws -> JSONValue)
    }

    /// Which deadline a request gets (architecture.md 5a).
    public enum Deadline: Sendable {
        /// The control-plane deadline (default 2 s).
        case controlPlane
        /// The request waits for cmux-tui to start a terminal: the terminal
        /// start deadline, and a timeout says the terminal may still appear.
        case terminalStart
        /// Chosen per request, for example by the action it runs.
        case perRequest(@Sendable (ControlRequest, ControlSnapshot) -> Bool)
    }

    public let name: String
    let body: Body
    public private(set) var deadline: Deadline = .controlPlane

    /// This method with `deadline` instead of the control-plane one.
    public func withDeadline(_ deadline: Deadline) -> ControlMethod {
        var method = self
        method.deadline = deadline
        return method
    }

    /// Whether `request` waits for a terminal to start.
    func startsTerminal(_ request: ControlRequest, _ snapshot: ControlSnapshot) -> Bool {
        switch deadline {
        case .controlPlane: false
        case .terminalStart: true
        case .perRequest(let decide): decide(request, snapshot)
        }
    }

    public var lane: Lane {
        switch body {
        case .snapshot: .snapshot
        case .mainActor: .mainActor
        case .async: .async
        }
    }

    public static func snapshot(_ name: String, _ body: @escaping @Sendable (ControlCall) throws -> JSONValue) -> ControlMethod {
        ControlMethod(name: name, body: .snapshot(body))
    }

    public static func mainActor(_ name: String, _ body: @escaping @MainActor @Sendable (ControlCall) throws -> ControlReply) -> ControlMethod {
        ControlMethod(name: name, body: .mainActor(body))
    }

    public static func async(_ name: String, _ body: @escaping @Sendable (ControlCall) async throws -> JSONValue) -> ControlMethod {
        ControlMethod(name: name, body: .async(body))
    }
}

/// Everything a method body sees about one request.
public struct ControlCall: Sendable {
    public let request: ControlRequest
    /// The snapshot current when the request was dispatched.
    public let snapshot: ControlSnapshot
    public let connection: ControlConnectionID
    /// When the request fails with `timeout` if it has not answered.
    public let deadline: ContinuousClock.Instant
    /// The request waits for a terminal to start: it has the terminal start
    /// deadline, and its timeout says the terminal may still appear.
    public let startsTerminal: Bool

    public init(request: ControlRequest, snapshot: ControlSnapshot, connection: ControlConnectionID,
                deadline: ContinuousClock.Instant, startsTerminal: Bool = false) {
        self.request = request
        self.snapshot = snapshot
        self.connection = connection
        self.deadline = deadline
        self.startsTerminal = startsTerminal
    }

    public var method: String { request.method }
    public var params: [String: JSONValue] { request.params }
}

/// What a main-actor method body returns.
public enum ControlReply: Sendable {
    /// Answered on the main actor.
    case value(JSONValue)
    /// The main actor did its part (optimistic apply, command dispatch);
    /// the rest runs off the main actor under the request's deadline.
    case followUp(@Sendable () async throws -> JSONValue)
}
