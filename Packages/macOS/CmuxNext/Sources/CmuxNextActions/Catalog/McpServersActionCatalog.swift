// Settings > MCP Servers (plans/cmux-next/mcp-connect-DESIGN.md row 3c): an internal page
// (`local-page:mcp-servers:<uuid>`) where the person reads and changes the MCP servers agents
// connected. Titles live in McpServersActions.xcstrings. The CLI reaches the page through
// `cmux mcp auth|key|policy NAME` (the `mcp.servers.open` control method), never through this
// action, because `cmux mcp` is its own CLI scope.

nonisolated enum McpServersActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "mcpServers.show", title: t("action.mcpServers.show", "MCP Servers"),
                keywords: ["mcp", "servers", "connections", "tools", "connectors", "integrations", "sign in", "key", "policy"],
                category: .settings, symbol: "puzzlepiece.extension", surfaces: [.palette, .keyboard],
                surfacePlan: ActionSurfacePlan(
                    // A page the person clicks in; `cmux mcp` opens it at a connection.
                    cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "McpServersActions", bundle: .module)
    }
}
