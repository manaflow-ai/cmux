import Foundation

/// One provider account CodeRouter holds for the team. Metadata only: no
/// route returns a stored credential (web/services/coderouter/README.md).
public struct LinkedAccount: Identifiable, Sendable, Equatable, Hashable {
    /// Which control-plane route owns the account.
    public enum Family: String, Sendable, Equatable, Hashable {
        /// `/api/coderouter/accounts` (Codex, OpenAI and OpenRouter keys, OpenCode Go).
        case native
        /// `/api/coderouter/claude-upstream` (Claude OAuth, Anthropic keys, Bedrock).
        case claude
    }

    /// The server's account id (a UUID; not personal data).
    public var id: String
    public var family: Family
    public var provider: AIProvider
    /// A handle from the account's stable identity and a display from its
    /// label with every email shortened (``AccountLabeler/server(namespace:id:label:providerAccountId:identifier:fallback:)``).
    /// The raw label is dropped at the client boundary.
    public var account: AccountLabel
    /// `active`, `refreshing`, `expired`, `broken`, `disabled`.
    public var state: String
    /// `private` or `team`; nil when the server does not say.
    public var visibility: String?

    public init(id: String, family: Family, provider: AIProvider, account: AccountLabel, state: String, visibility: String? = nil) {
        self.id = id
        self.family = family
        self.provider = provider
        self.account = account
        self.state = state
        self.visibility = visibility
    }

    /// What the UI shows: never an email.
    public var label: String { account.display }

    public var isHealthy: Bool { state == "active" || state == "refreshing" }
}

/// `GET /api/coderouter/accounts` rows (`CodeRouterAccountSummary`).
struct NativeAccountRow: Decodable {
    var id: String
    var provider: String
    var label: String?
    var providerAccountId: String?
    var state: String?
    var visibility: String?
}

/// `GET /api/coderouter/claude-upstream` rows.
struct ClaudeAccountRow: Decodable {
    var id: String
    var kind: String
    var label: String?
    var identifier: String?
    var state: String?
    var visibility: String?
}

extension LinkedAccount {
    init?(native row: NativeAccountRow, labeler: AccountLabeler) {
        guard let provider = AIProvider.fromCodeRouter(provider: row.provider) else { return nil }
        let account = labeler.server(namespace: provider.rawValue, id: row.id, label: row.label, providerAccountId: row.providerAccountId,
                                     fallback: provider.displayName)
        self.init(id: row.id, family: .native, provider: provider, account: account, state: row.state ?? "active", visibility: row.visibility)
    }

    init?(claude row: ClaudeAccountRow, labeler: AccountLabeler) {
        guard let provider = AIProvider.fromClaudeUpstream(kind: row.kind) else { return nil }
        let account = labeler.server(namespace: provider.rawValue, id: row.id, label: row.label, identifier: row.identifier,
                                     fallback: provider.displayName)
        self.init(id: row.id, family: .claude, provider: provider, account: account, state: row.state ?? "active", visibility: row.visibility)
    }
}
