/** MCP aliases for a verified CLI install grant. Approval still gates every external effect.
 * execute permits invoking agent tools; read-only and non-CLI installs never receive write authority.
 * This mapping is shared by token issuance and every live gateway recheck.
 */
export const mcpScopesForGrant = (kind: string | undefined, classes: ReadonlyArray<string> = []): ReadonlyArray<string> =>
  kind !== "cli" || !classes.includes("read") ? [] : classes.includes("execute") ? ["mcp:read", "mcp:write"] : ["mcp:read"]
