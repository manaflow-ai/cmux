import Foundation

/// `list-terminals`: every terminal in the daemon's registry with its
/// workspace and, once ended, its exit record (cmux-tui terminal-host.md).
public struct ListTerminalsRequest: DaemonRequest {
    public typealias Response = TerminalRegistryList
    public static let command = "list-terminals"
    public init() {}
}

public struct TerminalRegistryList: Decodable, Sendable {
    public var terminals: [TerminalRegistryEntry]
}

/// One registry terminal. Only the fields the app reads.
public struct TerminalRegistryEntry: Decodable, Sendable, Hashable {
    public var terminalID: String
    public var workspaceKey: String?
    public var lifecycle: String?
    public var exit: Exit?

    /// How it ended: `exit` and `signal` are its process ending; `unknown`
    /// means the daemon could not observe the end (its host was already
    /// gone), so the terminal was lost rather than ended.
    public struct Exit: Decodable, Sendable, Hashable {
        public var outcomeKind: String
        public var exitedAtMs: UInt64

        enum CodingKeys: String, CodingKey { case outcome, exitedAtMs = "exited_at_ms" }
        enum OutcomeKeys: String, CodingKey { case kind }

        public init(outcomeKind: String, exitedAtMs: UInt64) {
            self.outcomeKind = outcomeKind
            self.exitedAtMs = exitedAtMs
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            outcomeKind = try c.nestedContainer(keyedBy: OutcomeKeys.self, forKey: .outcome).decode(String.self, forKey: .kind)
            exitedAtMs = try c.decodeIfPresent(UInt64.self, forKey: .exitedAtMs) ?? 0
        }
    }

    public init(terminalID: String, workspaceKey: String?, lifecycle: String?, exit: Exit?) {
        self.terminalID = terminalID
        self.workspaceKey = workspaceKey
        self.lifecycle = lifecycle
        self.exit = exit
    }

    enum CodingKeys: String, CodingKey {
        case lifecycle, exit
        case terminalID = "terminal_id"
        case workspaceKey = "workspace_key"
    }
}

extension DaemonConnection {
    public func listTerminals() async throws -> [TerminalRegistryEntry] {
        try await request(ListTerminalsRequest()).terminals
    }
}
