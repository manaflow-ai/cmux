import Foundation

/// Turns a cmux-tui agent roster into the session hooks the Mac replays.
///
/// The mirror carries only an agent's own session identity: a
/// ``CloudVMAgentHookEvent/Kind/sessionStart`` when a terminal's agent
/// session id first appears or changes, and a
/// ``CloudVMAgentHookEvent/Kind/sessionEnd`` when an agent with a known
/// session id leaves the roster. Sidebar status for these agents is projected
/// from the roster elsewhere, so no turn or attention transitions are
/// replayed.
///
/// The daemon republishes its whole roster on every snapshot and each agent on
/// every upsert delta, so the same agent is observed many times; the mirror
/// remembers the last replayed session per terminal and emits nothing for a
/// repeat. Only agents with a supported hook integration are mirrored. An
/// agent whose terminal has no local pane yet is held and caught up once a
/// pane exists.
///
/// ```swift
/// var mirror = CloudVMAgentHookMirror()
/// let events = mirror.reconcile(
///     agents: state.agents,
///     routableTerminalIDs: ["term_1"]
/// )
/// ```
public struct CloudVMAgentHookMirror: Hashable, Sendable {
    private struct Replayed: Hashable, Sendable {
        var agent: String
        var agentSessionID: String
    }

    private var replayedByTerminalID: [String: Replayed] = [:]

    /// Creates an empty mirror; the first reconcile replays every routable session.
    public init() {}

    /// Returns the events that move the Mac from the last replayed sessions to `agents`.
    ///
    /// - Parameters:
    ///   - agents: The daemon's current agent roster.
    ///   - routableTerminalIDs: Terminals with a local pane that can receive
    ///     events. Other agents keep their last replayed session untouched.
    /// - Returns: Events in delivery order: session starts in roster order,
    ///   then session ends ordered by terminal id.
    public mutating func reconcile(
        agents: [CloudVMAgentState],
        routableTerminalIDs: Set<String>
    ) -> [CloudVMAgentHookEvent] {
        var events: [CloudVMAgentHookEvent] = []
        var next: [String: Replayed] = [:]
        for agentState in agents {
            guard let agent = Self.hookAgentName(for: agentState.agent) else { continue }
            let terminalID = agentState.terminalID
            let previous = replayedByTerminalID[terminalID].flatMap { $0.agent == agent ? $0 : nil }
            // A daemon that stops reporting the id (an older build after a
            // restart) has not changed sessions; keep the last known one.
            guard routableTerminalIDs.contains(terminalID),
                  let sessionID = agentState.agentSessionID else {
                if let previous { next[terminalID] = previous }
                continue
            }
            if sessionID != previous?.agentSessionID {
                events.append(CloudVMAgentHookEvent(
                    terminalID: terminalID,
                    agent: agent,
                    kind: .sessionStart,
                    agentSessionID: sessionID
                ))
            }
            next[terminalID] = Replayed(agent: agent, agentSessionID: sessionID)
        }
        for (terminalID, previous) in replayedByTerminalID.sorted(by: { $0.key < $1.key })
            where next[terminalID] == nil {
            events.append(CloudVMAgentHookEvent(
                terminalID: terminalID,
                agent: previous.agent,
                kind: .sessionEnd,
                agentSessionID: previous.agentSessionID
            ))
        }
        replayedByTerminalID = next
        return events
    }

    /// The cmux hook agent name for a daemon agent adapter id, or `nil` when
    /// the Mac has no hook integration that accepts this payload shape.
    private static func hookAgentName(for adapter: String?) -> String? {
        switch adapter?.lowercased() {
        case "claude", "claude-code", "claude_code", "claudecode":
            return "claude"
        default:
            return nil
        }
    }
}
