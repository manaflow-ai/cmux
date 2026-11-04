import Foundation

/// One approved tool of a connected MCP server and its policy, as Settings shows it.
public nonisolated struct McpServerTool: Equatable, Sendable, Hashable, Identifiable {
    /// The tool's name on its server (`create_issue`).
    public let name: String
    /// When an agent may call it.
    public let policy: McpToolPolicy

    public var id: String { name }

    public init(name: String, policy: McpToolPolicy) {
        self.name = name
        self.policy = policy
    }
}
