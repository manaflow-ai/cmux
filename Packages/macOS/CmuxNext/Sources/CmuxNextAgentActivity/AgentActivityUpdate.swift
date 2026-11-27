import Foundation

/// User operations the pane sends to the owning CUA host. The host decides;
/// the pane changes nothing until the host's update arrives.
public nonisolated enum AgentActivityUserOp: Sendable, Hashable {
    case stop(session: String)
    case pause(session: String)
    case resume(session: String)
    case watch(session: String, on: Bool)
    case export(session: String)
    case openAgent(session: String)
    case openTarget(session: String)
    case stopAll(machine: String)
}

/// Connection to one machine's CUA host.
public nonisolated enum AgentActivityConnection: Sendable, Hashable {
    case connected
    /// Computer use has not run on the machine yet (no host socket).
    case notStarted
    /// Accessibility or Screen Recording is missing for the helper.
    case notSetUp
    case unreachable
}

/// What a source pushes to the model.
public nonisolated enum AgentActivityUpdate: Sendable {
    /// The full current list of sessions of `machine` (replaces the last one).
    case sessions(machine: String, [AgentActivitySession])
    /// New events of one session, in seq order, starting at the next seq.
    case events(session: String, [AgentActivityEvent])
    case connection(machine: String, AgentActivityConnection)
}
