import Foundation

/// Why another machine's running chat could not open here (`agent-session-adopt`, cmux-tui/spec/
/// commands.md), for the refusals only an adopt gives; nil for the rest, which read as a start's
/// (the app's `AgentRemoteStartRefusal`).
public nonisolated struct AgentSessionAdoptRefusal {
    public let code: String
    public let machine: String

    public init(code: String, machine: String) {
        self.code = code
        self.machine = machine
    }

    /// The person's text for ``code`` on ``machine``.
    public var message: String? {
        switch code {
        case "agent_session.unknown_session":
            String(format: String(localized: "agentPane.adopt.unknownSession",
                                  defaultValue: "%@ runs no such agent chat of its own. Check the session id with acpmux ls on that machine.",
                                  bundle: .module), machine)
        case "agent_session.bound":
            String(localized: "agentPane.adopt.bound", defaultValue: "That agent tab already shows a chat. Open the session again in a new workspace.",
                   bundle: .module)
        default: nil
        }
    }

    /// ``message`` of `code` on `machine`.
    public static func message(code: String, machine: String) -> String? {
        Self(code: code, machine: machine).message
    }
}
