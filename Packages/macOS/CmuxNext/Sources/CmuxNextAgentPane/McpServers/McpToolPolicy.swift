import Foundation

/// When an agent may call one tool of a connected MCP server (acpmux `mcp_store.rs` `tool_policy`).
public nonisolated enum McpToolPolicy: String, CaseIterable, Sendable, Hashable, Identifiable {
    /// The call runs without a card.
    case always
    /// Each call shows the person a card first (acpmux's default for a tool with no policy).
    case ask
    /// The agent does not see the tool, and a call is refused.
    case never

    public var id: String { rawValue }

    /// The policy acpmux sent, or ``ask`` for a value it does not know (the daemon's own default).
    public init(wire: String?) {
        self = wire.flatMap(McpToolPolicy.init(rawValue:)) ?? .ask
    }
}
