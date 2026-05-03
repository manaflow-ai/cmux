import Foundation

// MARK: - Codex Validators

enum CodexValidators {
    /// JWT access tokens are 3 dot-separated base64url segments and start with `eyJ`
    /// (the base64 of the literal `{"`). Reject obviously-wrong values without
    /// trying to fully validate JWT structure or signature.
    static func isValidAccessToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("eyJ") else { return false }
        let illegal = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        if trimmed.unicodeScalars.contains(where: { illegal.contains($0) }) {
            return false
        }
        // Keep empty subsequences so consecutive or leading/trailing dots
        // surface as a bad token ("eyJ..abc.def" must not pass as 3 segments).
        let segments = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 && segments.allSatisfy({ !$0.isEmpty }) else { return false }
        let base64urlAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-=")
        for segment in segments {
            if segment.unicodeScalars.contains(where: { !base64urlAllowed.contains($0) }) {
                return false
            }
        }
        return true
    }

    /// `account_id` is an opaque string in `auth.json`: either empty (the
    /// header is optional) or a value safe to ship in an HTTP header. The
    /// literal string `null` is rejected because `jq -r .tokens.account_id`
    /// emits that sentinel when the field is unset; persisting it would send
    /// `chatgpt-account-id: null` and break otherwise-valid configurations.
    static func isValidAccountId(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed == "null" { return false }
        // Mirror the HTTP-layer sanitizer so a saved credential and the value
        // actually placed on the wire always agree.
        var disallowed = CharacterSet.controlCharacters
        disallowed.insert(charactersIn: ";,")
        disallowed.formUnion(.whitespacesAndNewlines)
        return trimmed.rangeOfCharacter(from: disallowed) == nil
    }
}

// MARK: - Codex Provider

extension Providers {
    static let codex: UsageProvider = UsageProvider(
        id: "codex",
        displayName: "Codex",
        keychainService: "com.cmuxterm.app.codex-accounts",
        credentialFields: [
            CredentialField(
                id: "accessToken",
                label: String(localized: "codex.accounts.editor.accessToken", defaultValue: "Access token"),
                placeholder: String(localized: "codex.accounts.editor.accessToken.placeholder", defaultValue: "eyJhbGciOi…"),
                isSecret: true,
                helpText: String(
                    localized: "codex.accounts.editor.accessToken.help",
                    defaultValue: "Run: jq -r .tokens.access_token < ~/.codex/auth.json"
                ),
                validate: CodexValidators.isValidAccessToken
            ),
            CredentialField(
                id: "accountId",
                label: String(localized: "codex.accounts.editor.accountId", defaultValue: "Account ID (optional)"),
                placeholder: String(localized: "codex.accounts.editor.accountId.placeholder", defaultValue: "abcd-1234-…"),
                isSecret: false,
                helpText: String(
                    localized: "codex.accounts.editor.accountId.help",
                    defaultValue: "Run: jq -r .tokens.account_id < ~/.codex/auth.json (leave blank if empty)"
                ),
                validate: CodexValidators.isValidAccountId
            ),
        ],
        statusPageURL: URL(string: "https://status.openai.com/"),
        statusSectionTitle: String(localized: "codex.accounts.status.section", defaultValue: "Codex status"),
        helpDocURL: URL(string: "https://github.com/manaflow-ai/cmux/blob/main/docs/usage-monitoring-setup.md#codex"),
        fetchUsage: CodexUsageFetcher.fetch,
        fetchStatus: {
            try await StatuspageIOFetcher.fetch(
                host: "status.openai.com",
                componentFilter: ["Codex Web", "Codex API", "CLI", "VS Code extension", "App"]
            )
        }
    )
}
