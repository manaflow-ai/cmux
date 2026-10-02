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

    public var id: String
    public var family: Family
    public var provider: AIProvider
    /// The server's label: an email, a label or a masked key. Never a secret.
    public var label: String
    /// `active`, `refreshing`, `expired`, `broken`, `disabled`.
    public var state: String
    /// `private` or `team`; nil when the server does not say.
    public var visibility: String?

    public init(id: String, family: Family, provider: AIProvider, label: String, state: String, visibility: String? = nil) {
        self.id = id
        self.family = family
        self.provider = provider
        self.label = label
        self.state = state
        self.visibility = visibility
    }

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
    init?(native row: NativeAccountRow) {
        guard let provider = AIProvider.fromCodeRouter(provider: row.provider) else { return nil }
        let label = [row.label, row.providerAccountId].compactMap { $0 }.first { !$0.isEmpty } ?? provider.displayName
        self.init(id: row.id, family: .native, provider: provider, label: label, state: row.state ?? "active", visibility: row.visibility)
    }

    init?(claude row: ClaudeAccountRow) {
        guard let provider = AIProvider.fromClaudeUpstream(kind: row.kind) else { return nil }
        let parts = [row.label, row.identifier].compactMap { $0 }.filter { !$0.isEmpty }
        self.init(id: row.id, family: .claude, provider: provider, label: parts.first ?? provider.displayName,
                  state: row.state ?? "active", visibility: row.visibility)
    }
}
