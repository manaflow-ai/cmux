public import Foundation

/// The person's answer to "may cmux add its tools to your coding agents?": the settings key
/// `agents.cmuxMcp` (schemas/settings/source/agent-defaults.json). `ask` is no answer yet, and keeps
/// what cmux did before the question existed (the `claude` and `codex` shims in a cmux terminal pass
/// the cmux MCP server); `on` passes it and writes it into the agents' own configs (`cmux setup
/// mcp`); `off` passes and writes nothing.
public enum AgentToolsChoice: String, Sendable, CaseIterable {
    case ask, on, off

    /// The settings key's path.
    public static let path = ["agents", "cmuxMcp"]
}

/// One coding agent on this Mac and whether its own config gives it cmux's tools, as `cmux setup
/// mcp` reads it.
public struct AgentToolsAgent: Sendable, Equatable {
    public enum State: String, Sendable {
        /// Installed; its config has no cmux server yet.
        case ready
        /// Its config runs cmux's server (`cmux mcp serve`).
        case added
        /// Another server named `cmux` is the person's; cmux leaves it.
        case conflict
        /// Its config could not be read or written.
        case failed
    }

    /// `claude` or `codex` (`cmux setup mcp`'s client ids, also the page's agent marks).
    public let id: String
    /// The product's own name ("Claude Code"), never translated.
    public let name: String
    public let state: State

    public init(id: String, name: String, state: State) {
        self.id = id
        self.name = name
        self.state = state
    }
}

public extension AgentToolsAgent {
    /// The installed agents of a `cmux --json setup mcp` report (stdout, also of a failed run):
    /// `ok` and `changed` are added (`changed` of `--remove` took cmux out: ready), `planned` is
    /// ready, a client whose own `user_action` is a `conflict` keeps the person's server, `failed`
    /// could not be read or written. An agent not installed is left out. Nil for no report.
    static func agents(setupReport data: Data, removing: Bool = false) -> [AgentToolsAgent]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let body = object["clients"] == nil ? (object["details"] as? [String: Any]) ?? object : object
        guard let clients = body["clients"] as? [[String: Any]] else { return nil }
        return clients.compactMap { client in
            guard client["installed"] as? Bool == true, let id = client["id"] as? String else { return nil }
            let name = client["name"] as? String ?? id
            let action = (client["user_action"] as? [String: Any])?["kind"] as? String
            let state: State = switch client["state"] as? String {
            case "failed": .failed
            case "needs_user" where action == "conflict": .conflict
            // `--remove`: `changed` took cmux out, `ok` found none, `planned` (a dry run) still has it.
            case "ok" where removing, "changed" where removing: .ready
            case "planned" where removing: .added
            case "planned": .ready
            case "ok", "changed": .added
            default: .ready
            }
            return AgentToolsAgent(id: id, name: name, state: state)
        }
    }
}

/// What the cmux Tools step reads and runs that only the App has: the setting, and the bundled
/// CLI's `cmux setup mcp` (the same code a person or an agent runs in a terminal).
@MainActor
public protocol AgentToolsSource: AnyObject {
    /// The answer in the settings file now.
    func agentToolsChoice() -> AgentToolsChoice
    /// Writes the answer through the settings owner; returns once the file has it, true when it did
    /// (false: no settings owner, or the write was refused, so `cmux setup mcp` would not see it).
    func setAgentToolsChoice(_ choice: AgentToolsChoice) async -> Bool
    /// The installed coding agents and their configs (`cmux setup mcp --dry-run`); nothing is
    /// written. Empty when none is installed or the CLI did not answer.
    func agentToolsAgents() async -> [AgentToolsAgent]
    /// Adds the cmux server to every installed agent's config (`cmux setup mcp`), or with `remove`
    /// takes cmux's own entry out (`cmux setup mcp --remove`). The agents as the run left them;
    /// nil when the CLI did not run or answer.
    func applyAgentTools(remove: Bool) async -> [AgentToolsAgent]?
}
