public import Foundation

/// The person's answer to "should agents you start in cmux get cmux's tools?": the settings key
/// `agents.cmuxMcp` (schemas/settings/source/agent-defaults.json). `ask` is no answer yet and `off`
/// is no: agents cmux starts (a Claude Code or Codex typed into a cmux terminal, the app's agent
/// chats) get no cmux MCP server, and the app asks at launch. `on`: each gets cmux's server, named
/// `cmux`, through its launch (the `claude` and `codex` shims, acpmux's session tools). cmux never
/// writes an agent's own config.
public enum AgentToolsChoice: String, Sendable, CaseIterable {
    case ask, on, off

    /// The settings key's path.
    public static let path = ["agents", "cmuxMcp"]
}

/// One coding agent on this Mac and whether it gets cmux's tools when cmux starts it, as `cmux
/// setup mcp` reports it.
public struct AgentToolsAgent: Sendable, Equatable {
    public enum State: String, Sendable {
        /// Installed; it gets no cmux tools in cmux yet (the answer is not `on`).
        case ready
        /// Started in cmux (its terminals, agent chats), it gets cmux's server.
        case terminals
        /// The report could not be read.
        case failed

        /// Whether the agent gets cmux's tools when cmux starts it.
        public var givesTools: Bool { self == .terminals }
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
    /// `terminals` gets cmux's tools in cmux, `failed` could not be read, any other state is
    /// ready. An agent not installed is left out. Nil for no report.
    static func agents(setupReport data: Data) -> [AgentToolsAgent]? {
        guard let body = report(data), let clients = body["clients"] as? [[String: Any]] else { return nil }
        return clients.compactMap { client in
            guard client["installed"] as? Bool == true, let id = client["id"] as? String else { return nil }
            let name = client["name"] as? String ?? id
            let state: State = switch client["state"] as? String {
            case "terminals": .terminals
            case "failed": .failed
            default: .ready
            }
            return AgentToolsAgent(id: id, name: name, state: state)
        }
    }

    /// The report's `manual.commands`: the lines a person runs themselves to use cmux's tools in
    /// agents started outside cmux (cmux never runs them). Empty for none or no report.
    static func manualCommands(setupReport data: Data) -> [String] {
        (report(data)?["manual"] as? [String: Any])?["commands"] as? [String] ?? []
    }

    private static func report(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["clients"] == nil ? (object["details"] as? [String: Any]) ?? object : object
    }
}

/// What the cmux Tools step reads and runs that only the App has: the setting, and the bundled
/// CLI's `cmux setup mcp` report (the same code a person or an agent runs in a terminal). Nothing
/// here writes an agent's own config.
@MainActor
public protocol AgentToolsSource: AnyObject {
    /// The answer in the settings file now.
    func agentToolsChoice() -> AgentToolsChoice
    /// Writes the answer through the settings owner; returns once the file has it, true when it did
    /// (false: no settings owner, or the write was refused).
    func setAgentToolsChoice(_ choice: AgentToolsChoice) async -> Bool
    /// The installed coding agents and whether each gets cmux's tools in cmux (`cmux setup mcp`,
    /// which writes nothing). Empty when none is installed or the CLI did not answer.
    func agentToolsAgents() async -> [AgentToolsAgent]
    /// The manual lines (`cmux setup mcp`'s `manual.commands`) a person runs themselves to use
    /// cmux's tools in agents started elsewhere. Empty when the CLI did not answer.
    func agentToolsManualCommands() async -> [String]
}

public extension AgentToolsSource {
    func agentToolsManualCommands() async -> [String] { [] }
}
