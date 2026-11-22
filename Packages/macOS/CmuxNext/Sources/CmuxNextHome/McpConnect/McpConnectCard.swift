import Foundation

/// What the MCP connect card shows (plans/cmux-next/mcp-connect-DESIGN.md section 3): the acpmux
/// `mcp_connect_request` record, as the app gets it. Every fact the person needs to decide is here;
/// a secret never is. The daemon resolved and checked the server before the card exists.
public struct McpConnectCard: Equatable, Sendable {
    /// Where the server runs.
    public enum Transport: Equatable, Sendable {
        /// A remote server at this URL.
        case remote(url: String)
        /// A local stdio server: argv exactly as it runs, its binary's SHA-256, and whether the
        /// launcher fetches code at run time (`npx`, `uvx`).
        case local(argv: [String], binarySHA256: String, fetchesCode: Bool)
    }

    /// How the server signs in.
    public enum Auth: Equatable, Sendable {
        case none
        /// OAuth 2.1 with PKCE in a cmux browser tab, asking for these scopes.
        case oauth(scopes: [String])
        /// A device code the person approves on the service's page.
        case device(scopes: [String])
        /// A key typed into the card's private field; `optional` when the server also works without one.
        case key(name: String, optional: Bool)
    }

    /// Who gets the server (design section 2b). Only the person's choice counts.
    public enum Scope: String, CaseIterable, Equatable, Sendable {
        case chat, chief, allChiefs, agents, everywhere
    }

    /// One tool of a connected server.
    public struct Tool: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case read, write, destructive }
        public var name: String
        public var kind: Kind
        /// The tool-text screen flagged it: it starts at Never.
        public var flagged: Bool

        public init(name: String, kind: Kind, flagged: Bool = false) {
            self.name = name
            self.kind = kind
            self.flagged = flagged
        }
    }

    public var requestID: String
    /// The agent that asked ("Chief", "a12").
    public var agent: String
    /// The agent's one sentence: what it will use the server for.
    public var reason: String
    public var title: String
    /// The registrable domain shown as "By".
    public var publisher: String
    /// A registry server at its exact URL.
    public var verified: Bool
    /// The host has an international name (shown in punycode).
    public var idn: Bool
    public var transport: Transport
    public var auth: Auth
    public var proposedScope: Scope
    /// Lines the daemon adds (an unverified server, a launcher that downloads code).
    public var warnings: [String]

    public init(requestID: String, agent: String, reason: String, title: String, publisher: String, verified: Bool,
                idn: Bool = false, transport: Transport, auth: Auth, proposedScope: Scope, warnings: [String] = []) {
        self.requestID = requestID
        self.agent = agent
        self.reason = reason
        self.title = title
        self.publisher = publisher
        self.verified = verified
        self.idn = idn
        self.transport = transport
        self.auth = auth
        self.proposedScope = proposedScope
        self.warnings = warnings
    }

    /// The card leads with its risk: an unverified, international-name or local server.
    public var risky: Bool {
        if case .local = transport { return true }
        return !verified || idn
    }

    /// The scopes the sign-in asks for (empty for none or a key).
    public var scopes: [String] {
        switch auth {
        case .oauth(let s), .device(let s): s
        case .none, .key: []
        }
    }
}
