import Foundation

/// One agent hook the Mac replays for an agent running in a cmux-tui terminal.
///
/// The cmux-tui daemon reduces an agent's own hooks into its roster
/// (``CloudVMAgentState``). The Mac turns roster transitions back into the
/// hook subcommands its local hook CLI already understands, so a remote agent
/// drives the sidebar through the same path as a local one. Produced by
/// ``CloudVMAgentHookMirror``.
public struct CloudVMAgentHookEvent: Hashable, Sendable {
    /// The hook transition the event replays.
    public enum Kind: String, Hashable, Sendable {
        /// The agent started, or switched to, a session. Carries the session id.
        case sessionStart = "session-start"
        /// The agent started working on a turn.
        case promptSubmit = "prompt-submit"
        /// The agent is blocked on the person (approval, question, plan review).
        case needsInput = "notification"
        /// The agent finished its turn and is idle at its prompt.
        case stop = "stop"
        /// The agent left the roster: its session ended.
        case sessionEnd = "session-end"

        /// The hook CLI subcommand that applies this transition.
        public var subcommand: String { rawValue }

        /// The native hook event name the replayed payload reports.
        var hookEventName: String {
            switch self {
            case .sessionStart: return "SessionStart"
            case .promptSubmit: return "UserPromptSubmit"
            case .needsInput: return "Notification"
            case .stop: return "Stop"
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
    /// The agent's own session id, or `nil` while the daemon does not report it.
    public let agentSessionID: String?

    /// Creates an event.
    /// - Parameters:
    ///   - terminalID: The daemon terminal the agent runs in.
    ///   - agent: The cmux hook agent name.
    ///   - kind: The transition to replay.
    ///   - agentSessionID: The agent's own session id, when known.
    public init(terminalID: String, agent: String, kind: Kind, agentSessionID: String?) {
        self.terminalID = terminalID
        self.agent = agent
        self.kind = kind
        self.agentSessionID = agentSessionID
    }

    /// The hook CLI subcommand for this event.
    public var subcommand: String { kind.subcommand }

    /// The JSON hook payload for the local hook CLI.
    ///
    /// It carries only the session id and event name (plus the
    /// `permission_prompt` notification type for ``Kind/needsInput``). It never
    /// carries message text, working directory, or transcript paths: those
    /// describe the remote host, and the daemon's own durable notification rows
    /// already carry the human-readable text.
    public var payload: String {
        var object: [String: String] = ["hook_event_name": kind.hookEventName]
        if let agentSessionID {
            object["session_id"] = agentSessionID
        }
        if kind == .needsInput {
            object["notification_type"] = "permission_prompt"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
