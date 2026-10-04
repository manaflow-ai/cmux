public import CmuxAgentCursor

/// Scripted agent cursor input for the DEBUG verb `debug.agent_cursor.demo`:
/// one action becomes either an `automation.input` event (published into a
/// real cursor stack) or a lease state change. Per-session `seq` is gap-free
/// over published events and starts again after `end`.
public struct AgentCursorDemo: Sendable {
    public enum Step: Equatable, Sendable {
        case input(AutomationInputEvent)
        case lease(session: String, state: AgentCursorLeaseState?)
    }

    public enum Failure: Error, Equatable, Sendable {
        case unknownAction(String)
        case pointRequired(String)
    }

    private var nextSeq: [String: UInt64] = [:]

    public init() {}

    public mutating func step(
        action: String, session: String, target: String, x: Double?, y: Double?, zoom: Double? = nil, tMs: Double
    ) throws(Failure) -> Step {
        _ = (action, session, target, x, y, zoom, tMs, nextSeq)
        throw .unknownAction(action)
    }
}
