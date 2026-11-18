// The path and default are generated from schemas/settings/source/mcp-servers.json
// (Schema/SettingsSchema+McpServers.generated.swift).

/// `agents.mcpServers.enabled` in cmux.json: whether new agent chats get the person's saved MCP
/// servers (Settings > MCP Servers). The acpmux daemon reads it when it creates a chat
/// (`agent_tools.rs` `saved_servers_off`); the app only shows it.
public nonisolated enum McpServersSettings {}
