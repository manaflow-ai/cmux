import Foundation

// Codex CLI and Claude Code: the two agent CLIs whose sign-ins CodeRouter
// can link. Both renew their access token with a refresh token, so an
// expired access token alone is not an expired sign-in.
extension ProviderDetector {
    /// The Codex home: `$CODEX_HOME`, else `~/.codex`.
    var codexHome: URL { environment.directory("CODEX_HOME", fallback: ".codex") }

    /// `auth.json` in the Codex home: ChatGPT tokens (identity from the
    /// id token's email and plan claims) or an API key. When the CLI keeps
    /// credentials in the Keychain (`cli_auth_credentials_store = "keyring"`
    /// in config.toml), only the item's presence is checked.
    func detectCodex() -> ProviderDetection {
        let file = codexHome.appendingPathComponent("auth.json")
        let source = DetectionSource.file(environment.display(file))
        guard environment.files.exists(file) else {
            if codexUsesKeyring {
                let found = environment.keychain.hasGenericPassword(service: Self.codexKeychainService)
                return ProviderDetection(provider: .codex, status: found ? .signedIn : .missing,
                                         sources: found ? [.keychain(Self.codexKeychainService)] : [])
            }
            return .missing(.codex)
        }
        guard let root = environment.jsonObject(at: file) else {
            return ProviderDetection(provider: .codex, status: .unknown, sources: [source])
        }
        if let tokens = root["tokens"] as? [String: Any] {
            let claims = (tokens["id_token"] as? String).flatMap(JWTClaims.init(token:))
            let canRefresh = Self.nonEmpty(tokens["refresh_token"])
            let accessExpiry = (tokens["access_token"] as? String).flatMap(JWTClaims.init(token:))?.expiry
            let expired = !canRefresh && (accessExpiry.map { $0 <= environment.now } ?? true)
            let plan = claims?.chatGPTPlan
            return ProviderDetection(provider: .codex, status: expired ? .expired : .signedIn,
                                     account: account(.codex, claims?.email, plan: plan), plan: plan, sources: [source])
        }
        if Self.nonEmpty(root["OPENAI_API_KEY"]) {
            return ProviderDetection(provider: .codex, status: .signedIn, plan: "API key", sources: [source])
        }
        return ProviderDetection(provider: .codex, status: .missing, sources: [source])
    }

    static let codexKeychainService = "Codex Auth"

    /// Whether config.toml sets `cli_auth_credentials_store = "keyring"`.
    var codexUsesKeyring: Bool {
        let config = codexHome.appendingPathComponent("config.toml")
        guard let data = environment.files.data(at: config), let text = String(data: data, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] == "cli_auth_credentials_store"
                && parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) == "keyring"
        }
    }

    /// Claude Code: `$CLAUDE_CODE_OAUTH_TOKEN`, the `.credentials.json`
    /// file (Linux layout, also used when the Keychain is unavailable),
    /// or the macOS Keychain item `Claude Code-credentials`. The account
    /// label comes from `oauthAccount.emailAddress` in `.claude.json`.
    func detectClaudeCode() -> ProviderDetection {
        let configDir = environment.directory("CLAUDE_CONFIG_DIR", fallback: ".claude")
        let identity = claudeIdentity(configDir: configDir)
        if environment.value("CLAUDE_CODE_OAUTH_TOKEN") != nil {
            return ProviderDetection(provider: .claude, status: .signedIn, account: identity.account, plan: identity.plan,
                                     sources: [.environment("CLAUDE_CODE_OAUTH_TOKEN")])
        }
        let file = configDir.appendingPathComponent(".credentials.json")
        if environment.files.exists(file) {
            let source = DetectionSource.file(environment.display(file))
            guard let oauth = environment.jsonObject(at: file)?["claudeAiOauth"] as? [String: Any] else {
                return ProviderDetection(provider: .claude, status: .unknown, sources: [source])
            }
            let canRefresh = Self.nonEmpty(oauth["refreshToken"])
            let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            let expired = !canRefresh && (expiresAt.map { $0 <= environment.now } ?? true)
            return ProviderDetection(provider: .claude, status: expired ? .expired : .signedIn, account: identity.account,
                                     plan: identity.plan, sources: [source])
        }
        if environment.keychain.hasGenericPassword(service: Self.claudeKeychainService) {
            return ProviderDetection(provider: .claude, status: .signedIn, account: identity.account, plan: identity.plan,
                                     sources: [.keychain(Self.claudeKeychainService)])
        }
        return .missing(.claude)
    }

    static let claudeKeychainService = "Claude Code-credentials"

    /// `.claude.json` next to the config dir's parent (`~/.claude.json`),
    /// or inside `$CLAUDE_CONFIG_DIR`.
    private func claudeIdentity(configDir: URL) -> (account: AccountLabel?, plan: String?) {
        let candidates = environment.value("CLAUDE_CONFIG_DIR") != nil
            ? [configDir.appendingPathComponent(".claude.json")]
            : [environment.home.appendingPathComponent(".claude.json"), configDir.appendingPathComponent(".claude.json")]
        for url in candidates {
            guard let oauthAccount = environment.jsonObject(at: url)?["oauthAccount"] as? [String: Any] else { continue }
            let organization = (oauthAccount["organizationName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return (account(.claude, oauthAccount["emailAddress"] as? String, plan: organization), organization)
        }
        return (nil, nil)
    }

    static func nonEmpty(_ value: Any?) -> Bool {
        guard let string = value as? String else { return false }
        return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
