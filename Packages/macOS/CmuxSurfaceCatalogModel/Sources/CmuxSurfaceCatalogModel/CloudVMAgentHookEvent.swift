import Foundation

/// One session hook the Mac replays for an agent running in a cmux-tui terminal.
///
/// The cmux-tui daemon reduces an agent's own hooks into its roster
/// (``CloudVMAgentState``). The Mac turns a roster agent's session identity
/// back into the session hooks its local hook CLI already understands, so the
/// remote agent's session is known on this Mac. Produced by
/// ``CloudVMAgentHookMirror``.
public struct CloudVMAgentHookEvent: Hashable, Sendable {
    /// The hook transition the event replays.
    public enum Kind: String, Hashable, Sendable {
        /// The agent started, or switched to, a session.
        case sessionStart = "session-start"
        /// An agent with a known session left the roster: its session ended.
        case sessionEnd = "session-end"

        /// The hook CLI subcommand that applies this transition.
        public var subcommand: String { rawValue }

        /// The native hook event name the replayed payload reports.
        var hookEventName: String {
            switch self {
            case .sessionStart: return "SessionStart"
            case .sessionEnd: return "SessionEnd"
            }
        }
    }

    /// The daemon terminal the agent runs in.
    public let terminalID: String
    /// The cmux hook agent name, such as `claude`.
    public let agent: String
    /// The transition to replay.
    public let kind: Kind
    /// The agent's own session id (Claude's `session_id`).
    public let agentSessionID: String

    /// Creates an event.
    /// - Parameters:
    ///   - terminalID: The daemon terminal the agent runs in.
    ///   - agent: The cmux hook agent name.
    ///   - kind: The transition to replay.
    ///   - agentSessionID: The agent's own session id.
    public init(terminalID: String, agent: String, kind: Kind, agentSessionID: String) {
        self.terminalID = terminalID
        self.agent = agent
        self.kind = kind
        self.agentSessionID = agentSessionID
    }

    /// The hook CLI subcommand for this event.
    public var subcommand: String { kind.subcommand }

    /// The JSON hook payload for the local hook CLI.
    ///
    /// It carries only the session id and event name. It never carries a
    /// working directory or transcript path: those describe the remote host.
    public var payload: String {
        let object = ["hook_event_name": kind.hookEventName, "session_id": agentSessionID]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
