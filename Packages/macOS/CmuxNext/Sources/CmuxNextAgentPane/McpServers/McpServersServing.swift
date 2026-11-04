public import Foundation

/// The person's MCP connection methods of acpmux (`_acpmux/mcp_connections`, `mcp_policy`,
/// `mcp_remove`, `mcp_sign_in`, `mcp_set_key`, `mcp_approve_tools`, `mcp_audit`), which acpmux answers only on a
/// person-proven connection. ``AcpmuxMcpServersService`` is the live one; tests pass a fake.
@MainActor
public protocol McpServersServing: AnyObject {
    /// Every connection, in the daemon's order.
    /// - Throws: ``McpServersFailure``.
    func connections() async throws -> [McpServerConnection]
    /// Sets one tool's policy.
    /// - Throws: ``McpServersFailure``.
    func setPolicy(_ policy: McpToolPolicy, tool: String, connection: String) async throws
    /// Removes a connection and its secret.
    /// - Throws: ``McpServersFailure``.
    func remove(connection: String) async throws
    /// Starts the OAuth sign-in of a connection.
    /// - Returns: The authorize URL for the person to open in a cmux browser tab.
    /// - Throws: ``McpServersFailure``.
    func signIn(connection: String) async throws -> URL
    /// Gives a key connection its key. The caller drops `key` after the call.
    /// - Throws: ``McpServersFailure``.
    func setKey(_ key: String, connection: String) async throws -> McpKeyOutcome
    /// Approves the tools a connection lists now, the held ones included (pins their current text).
    /// - Returns: The names acpmux approved (the ones that were held).
    /// - Throws: ``McpServersFailure``.
    func approveTools(connection: String) async throws -> [String]
    /// The newest audit lines, oldest first, each one compact JSON (digests only, never a value).
    /// - Throws: ``McpServersFailure``.
    func audit(limit: Int) async throws -> [String]
}
