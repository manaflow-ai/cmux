import Foundation

// MARK: - Claude Provider Definition

extension Providers {
    static let claude: UsageProvider = UsageProvider(
        id: "claude",
        displayName: "Claude",
        keychainService: "com.cmuxterm.app.claude-accounts",
        credentialFields: [
            CredentialField(
                id: "sessionKey",
                label: String(localized: "claude.accounts.editor.sessionKey", defaultValue: "Session key"),
                placeholder: String(localized: "claude.accounts.editor.sessionKey.placeholder", defaultValue: "sk-ant-sid01-…"),
                isSecret: true,
                helpText: String(localized: "claude.accounts.editor.sessionKey.help", defaultValue: "From claude.ai cookies"),
                validate: ProviderClaudeValidators.isValidSessionKey
            ),
            CredentialField(
                id: "orgId",
                label: String(localized: "claude.accounts.editor.orgId", defaultValue: "Organization ID"),
                placeholder: String(localized: "claude.accounts.editor.orgId.placeholder", defaultValue: "UUID"),
                isSecret: false,
                helpText: String(localized: "claude.accounts.editor.orgId.help", defaultValue: "From claude.ai network requests"),
                validate: ProviderClaudeValidators.isValidOrgId
            ),
        ],
        statusPageURL: URL(string: "https://status.claude.com/"),
        statusSectionTitle: String(localized: "claude.accounts.status.section", defaultValue: "Claude.ai status"),
        helpDocURL: URL(string: "https://github.com/manaflow-ai/cmux/blob/main/docs/usage-monitoring-setup.md#claude"),
        fetchUsage: { secret in
            try await ClaudeUsageFetcher.fetch(secret: secret)
        },
        fetchStatus: {
            try await StatuspageIOFetcher.fetch(
                host: "status.claude.com",
                componentFilter: ["claude.ai", "Claude API (api.anthropic.com)", "Claude Code"]
            )
        }
    )
}

// MARK: - Claude Validators

enum ProviderClaudeValidators {
    private static let segmentReserved = CharacterSet(charactersIn: "/:@;=?#")

    static func isValidOrgId(_ orgId: String) -> Bool {
        let trimmed = orgId.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.contains("..")
            && trimmed.rangeOfCharacter(from: segmentReserved) == nil
            // Embedded whitespace percent-encodes to `%20` and produces a
            // different (missing) organization path.
            && trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    /// Rejects whitespace-only input and any character that would corrupt the
    /// `Cookie` header (attribute separators or control bytes). A leading
    /// `sessionKey=` prefix is tolerated — it is stripped at fetch time — so
    /// the editor accepts a pasted cookie value verbatim.
    static func isValidSessionKey(_ sessionKey: String) -> Bool {
        let body = strippedSessionKey(sessionKey)
        guard !body.isEmpty else { return false }
        var disallowed = CharacterSet.controlCharacters
        // `;` and `,` are the separators that would split the `Cookie`
        // header and let a paste smuggle extra directives. `=` is left in
        // because cookie values (e.g. base64-padded tokens) legitimately
        // contain it.
        disallowed.insert(charactersIn: ";,\n\r")
        // Embedded whitespace in a cookie value is not a valid sessionKey and
        // the server would reject it outright; catch it here so the editor
        // shows the right guidance instead of surfacing a fetch failure.
        disallowed.formUnion(.whitespacesAndNewlines)
        return body.rangeOfCharacter(from: disallowed) == nil
    }

    /// Trims whitespace and removes every leading `sessionKey=` prefix.
    /// Loop-stripping keeps the editor validator and the fetcher's `Cookie`
    /// header in lockstep even when a paste like `sessionKey=sessionKey=abc`
    /// carries the prefix twice.
    static func strippedSessionKey(_ sessionKey: String) -> String {
        var trimmed = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "sessionKey="
        while trimmed.hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count))
        }
        return trimmed
    }
}
