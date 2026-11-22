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

    /// One verb call's fields after aliases: `action` or `kind`; `x`/`y` or
    /// `point {x, y}` (the form agent-cursor-visibility-live.py sends).
    public struct Request: Equatable, Sendable {
        public var action: String
        public var x: Double?
        public var y: Double?

        public init(action: String?, kind: String?, x: Double?, y: Double?, pointX: Double?, pointY: Double?) {
            self.action = action ?? kind ?? "report"
            self.x = x ?? pointX
            self.y = y ?? pointY
        }
    }

    private var nextSeq: [String: UInt64] = [:]

    public init() {}

    public mutating func step(
        action: String, session: String, target: String, x: Double?, y: Double?, zoom: Double? = nil, tMs: Double
    ) throws(Failure) -> Step {
        switch action {
        case "pause":
            return .lease(session: session, state: .paused)
        case "takeover":
            return .lease(session: session, state: .userDriving)
        case "resume":
            return .lease(session: session, state: .driving)
        case "end":
            nextSeq[session] = nil
            return .lease(session: session, state: nil)
        default:
            break
        }
        let kinds: [String: AutomationInputEvent.Kind] = [
            "move": .move, "click": .click, "double_click": .doubleClick, "right_click": .rightClick,
            "type": .type, "key": .key,
        ]
        guard let kind = kinds[action] else { throw .unknownAction(action) }
        let needsPoint = kind != .type && kind != .key
        let point: AutomationInputEvent.Point?
        if let x, let y {
            point = .init(x: x, y: y)
        } else if needsPoint {
            throw .pointRequired(action)
        } else {
            point = nil
        }
        let seq = nextSeq[session] ?? 0
        nextSeq[session] = seq + 1
        return .input(AutomationInputEvent(
            sessionID: session, targetID: target, seq: seq, kind: kind, space: .viewport,
            point: point, zoom: zoom, tMs: tMs
        ))
    }
}
