#if DEBUG
import Foundation

/// DEBUG ONLY: the sample servers of the MCP Connect Card Playground, one per kind of card the
/// daemon makes (design section 1): a verified OAuth server, a device-code server, an optional-key
/// server, an unverified URL, an international-name look-alike and a local command.
public enum McpConnectCardFixture: Int, CaseIterable, Sendable {
    case linear, github, context7, customURL, lookalike, localCommand

    /// The DEV-only playground label.
    public var title: String {
        switch self {
        case .linear: "Linear (verified, OAuth)"
        case .github: "GitHub (verified, device code)"
        case .context7: "Context7 (key, optional)"
        case .customURL: "Custom URL (unverified)"
        case .lookalike: "Look-alike host (IDN)"
        case .localCommand: "Local command (npx)"
        }
    }

    public var card: McpConnectCard {
        switch self {
        case .linear:
            McpConnectCard(requestID: "req_linear", agent: "Chief", reason: "to read and file the issues you mention",
                           title: "Linear", publisher: "linear.app", verified: true,
                           transport: .remote(url: "https://mcp.linear.app/mcp"), auth: .oauth(scopes: ["read", "write"]),
                           proposedScope: .chief)
        case .github:
            McpConnectCard(requestID: "req_github", agent: "a12", reason: "to open the pull request for this fix",
                           title: "GitHub", publisher: "githubcopilot.com", verified: true,
                           transport: .remote(url: "https://api.githubcopilot.com/mcp/"),
                           auth: .device(scopes: ["repo", "read:org"]), proposedScope: .chat)
        case .context7:
            McpConnectCard(requestID: "req_ctx7", agent: "Chief", reason: "to look up current library docs",
                           title: "Context7", publisher: "context7.com", verified: true,
                           transport: .remote(url: "https://mcp.context7.com/mcp"),
                           auth: .key(name: "CONTEXT7_API_KEY", optional: true), proposedScope: .allChiefs)
        case .customURL:
            McpConnectCard(requestID: "req_custom", agent: "Chief", reason: "the README says to connect it",
                           title: "mcp.acme-tools.dev", publisher: "acme-tools.dev", verified: false,
                           transport: .remote(url: "https://mcp.acme-tools.dev/mcp"), auth: .oauth(scopes: []),
                           proposedScope: .chief)
        case .lookalike:
            McpConnectCard(requestID: "req_idn", agent: "a7", reason: "to file the bug in Linear",
                           title: "mcp.xn--lnear-6ve.app", publisher: "xn--lnear-6ve.app", verified: false, idn: true,
                           transport: .remote(url: "https://mcp.xn--lnear-6ve.app/mcp"), auth: .oauth(scopes: ["read", "write"]),
                           proposedScope: .chat)
        case .localCommand:
            McpConnectCard(requestID: "req_local", agent: "Chief", reason: "to query the local Postgres",
                           title: "postgres-mcp", publisher: "this Mac", verified: false,
                           transport: .local(argv: ["npx", "-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost/dev"],
                                             binarySHA256: "9f2c4e1b7a60d8c35e1f0a2b4c6d8e0f1a3b5c7d9e1f2a4b6c8d0e2f4a6b8c0d",
                                             fetchesCode: true),
                           auth: .none, proposedScope: .chief)
        }
    }

    /// The tools the playground's "connected" step shows.
    public var tools: [McpConnectCard.Tool] {
        switch self {
        case .localCommand:
            [McpConnectCard.Tool(name: "query", kind: .read),
             McpConnectCard.Tool(name: "list_tables", kind: .read),
             McpConnectCard.Tool(name: "describe_table", kind: .read, flagged: true)]
        default:
            [McpConnectCard.Tool(name: "list_issues", kind: .read),
             McpConnectCard.Tool(name: "get_issue", kind: .read),
             McpConnectCard.Tool(name: "search_documentation", kind: .read),
             McpConnectCard.Tool(name: "create_issue", kind: .write),
             McpConnectCard.Tool(name: "update_issue", kind: .write),
             McpConnectCard.Tool(name: "create_comment", kind: .write),
             McpConnectCard.Tool(name: "delete_comment", kind: .destructive)]
        }
    }
}
#endif
