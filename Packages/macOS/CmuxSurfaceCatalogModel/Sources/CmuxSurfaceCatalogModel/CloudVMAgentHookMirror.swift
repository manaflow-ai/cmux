import Foundation

/// Turns a cmux-tui agent roster into the hook events the Mac replays.
///
/// The daemon republishes its whole roster on every snapshot and each agent on
/// every upsert delta, so the same state is observed many times. The mirror
/// remembers what it last replayed per terminal and emits an event only for a
/// transition: a new or changed agent session id, a changed state, or an agent
/// leaving the roster.
///
/// Only agents with a supported hook integration are mirrored; others are
/// ignored. An agent whose terminal has no local pane yet is held at its last
/// replayed state and caught up once a pane exists, instead of losing the
/// transition.
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
        var state: String
        var agentSessionID: String?
    }

    private var replayedByTerminalID: [String: Replayed] = [:]

    /// Creates an empty mirror; the first reconcile replays every routable agent.
    public init() {}

    /// Returns the events that move the Mac from the last replayed roster to `agents`.
    ///
    /// - Parameters:
    ///   - agents: The daemon's current agent roster.
    ///   - routableTerminalIDs: Terminals with a local pane that can receive
    ///     events. Other agents keep their last replayed state untouched.
    /// - Returns: Events in delivery order. Within one terminal a
    ///   ``CloudVMAgentHookEvent/Kind/sessionStart`` precedes the state event.
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
            guard routableTerminalIDs.contains(terminalID) else {
                if let previous { next[terminalID] = previous }
                continue
            }
            // A daemon that stops reporting the id (an older build after a
            // restart) has not changed sessions; keep the last known one.
            let sessionID = agentState.agentSessionID ?? previous?.agentSessionID
            let sessionChanged = agentState.agentSessionID != nil
                && agentState.agentSessionID != previous?.agentSessionID
            if sessionChanged {
                events.append(CloudVMAgentHookEvent(
                    terminalID: terminalID,
                    agent: agent,
                    kind: .sessionStart,
                    agentSessionID: sessionID
                ))
            }
            if previous == nil || sessionChanged || previous?.state != agentState.state,
               let kind = Self.stateEventKind(for: agentState.state) {
                events.append(CloudVMAgentHookEvent(
                    terminalID: terminalID,
                    agent: agent,
                    kind: kind,
                    agentSessionID: sessionID
                ))
            }
            next[terminalID] = Replayed(agent: agent, state: agentState.state, agentSessionID: sessionID)
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

    /// The hook transition for a daemon agent state (`mux.rs` `AgentState`).
    /// `done` never reaches the roster (the daemon deletes the agent), and
    /// `unknown` has no sidebar meaning.
    private static func stateEventKind(for state: String) -> CloudVMAgentHookEvent.Kind? {
        switch state {
        case "working": return .promptSubmit
        case "blocked": return .needsInput
        case "idle": return .stop
        default: return nil
        }
    }
}
