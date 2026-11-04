import Foundation

/// One connected MCP server as `_acpmux/mcp_connections` lists it for the person (acpmux
/// `mcp_store.rs` `Connection::row`). It never holds a secret: `hasSecret` only says whether the
/// daemon keeps a key or tokens for it.
public nonisolated struct McpServerConnection: Equatable, Sendable, Identifiable {
    /// `mcp_` and 16 hex digits.
    public let id: String
    /// The prefix of its tools for an agent (`linear`), `[a-z0-9-]`.
    public let name: String
    public let title: String
    /// The registrable domain of the server's URL (`linear.app`).
    public let publisher: String
    /// True only when the URL is the exact URL of a known registry entry.
    public let verified: Bool
    /// The exact server URL.
    public let url: String
    /// `none`, `key`, `oauth` or `discover`.
    public let auth: String
    public let hasSecret: Bool
    /// `chat`, `chief`, `allChiefs`, `agents` or `everywhere`.
    public let scope: String
    /// `connected`, `needsSignIn`, `needsKey`, `failed` or `revoked`.
    public let state: String
    /// Milliseconds since 1970 when the person approved it.
    public let addedAt: UInt64
    public let tools: [McpServerTool]
    /// The tools listed now whose text is new or changed since the person approved them (after a
    /// key or a sign-in): acpmux holds them from agents until the person approves them
    /// (`_acpmux/mcp_approve_tools`). Empty from a daemon that does not say.
    public let held: [String]

    public init(id: String, name: String, title: String, publisher: String, verified: Bool, url: String,
                auth: String, hasSecret: Bool, scope: String, state: String, addedAt: UInt64, tools: [McpServerTool],
                held: [String] = []) {
        self.id = id
        self.name = name
        self.title = title
        self.publisher = publisher
        self.verified = verified
        self.url = url
        self.auth = auth
        self.hasSecret = hasSecret
        self.scope = scope
        self.state = state
        self.addedAt = addedAt
        self.tools = tools
        self.held = held
    }

    /// One row of `_acpmux/mcp_connections`; nil without an `id`.
    public init?(row: [String: Any]) {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        let text = { (key: String) in row[key] as? String ?? "" }
        self.init(
            id: id, name: text("name"), title: text("title"), publisher: text("publisher"),
            verified: row["verified"] as? Bool ?? false, url: text("url"), auth: text("auth"),
            hasSecret: row["hasSecret"] as? Bool ?? false, scope: text("scope"), state: text("state"),
            addedAt: (row["addedAt"] as? NSNumber)?.uint64Value ?? 0,
            tools: (row["tools"] as? [[String: Any]] ?? []).compactMap { tool in
                guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
                return McpServerTool(name: name, policy: McpToolPolicy(wire: tool["policy"] as? String))
            },
            held: (row["held"] as? [Any] ?? []).compactMap { $0 as? String })
    }

    /// The person signs in to it in a browser (OAuth).
    public var signsIn: Bool { auth == "oauth" || auth == "discover" }
    /// The person gives it a key.
    public var takesKey: Bool { auth == "key" }

    /// Whether `reference` names this connection: its id, or its name (case-insensitive).
    public func matches(_ reference: String) -> Bool {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        return !reference.isEmpty && (reference == id || reference.lowercased() == name.lowercased())
    }
}
