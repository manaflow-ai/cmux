import Foundation

/// Why Connect cannot build a credential. No case carries a secret.
public enum CredentialResolutionError: Error, Sendable, Equatable {
    /// CodeRouter does not route this provider.
    case unsupported
    /// The provider needs a pasted secret (a Claude OAuth token, a key).
    case needsPastedSecret
    /// The pasted text is not this provider's credential format.
    case invalidFormat
    /// The local sign-in lacks a field CodeRouter requires (re-authenticate).
    case incompleteSignIn
    /// AWS keys or region missing from the environment.
    case missingEnvironment(String)
}

/// Builds the credential Connect sends to CodeRouter, on an explicit user
/// action only. Secrets are read here, kept in memory for the one request,
/// and never logged, stored or shown.
public struct CredentialResolver: Sendable {
    public let environment: DetectionEnvironment
    public let keys: any ProviderKeyStoring

    public init(environment: DetectionEnvironment, keys: any ProviderKeyStoring) {
        self.environment = environment
        self.keys = keys
    }

    /// `pasted` wins over the environment and the saved key.
    public func credential(for provider: AIProvider, pasted: String?, label: String? = nil) throws -> CodeRouterCredential {
        let pasted = pasted?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch provider.codeRouterLink {
        case .unsupported:
            throw CredentialResolutionError.unsupported
        case .codexOAuth:
            return .codex(try codexCredential())
        case .apiKey(let serverProvider):
            let key = try pasted ?? storedKey(provider)
            guard Self.looksLikeKey(key) else { throw CredentialResolutionError.invalidFormat }
            return .apiKey(serverProvider: serverProvider, key: key, label: label)
        case .anthropicAPIKey:
            let key = try pasted ?? storedKey(provider)
            guard key.hasPrefix("sk-ant-"), !key.hasPrefix("sk-ant-oat"), Self.looksLikeKey(key) else {
                throw CredentialResolutionError.invalidFormat
            }
            return .anthropicAPIKey(key, label: label)
        case .claudeOAuthToken:
            guard let token = pasted ?? environment.value("CLAUDE_CODE_OAUTH_TOKEN") else {
                throw CredentialResolutionError.needsPastedSecret
            }
            guard token.hasPrefix("sk-ant-oat01-"), Self.looksLikeKey(token) else { throw CredentialResolutionError.invalidFormat }
            return .claudeOAuthToken(token, label: label)
        case .bedrockKeys:
            guard let keyID = environment.value("AWS_ACCESS_KEY_ID"), let secret = environment.value("AWS_SECRET_ACCESS_KEY") else {
                throw CredentialResolutionError.missingEnvironment("AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY")
            }
            guard let region = environment.value("AWS_REGION") ?? environment.value("AWS_DEFAULT_REGION") else {
                throw CredentialResolutionError.missingEnvironment("AWS_REGION")
            }
            return .bedrock(region: region, accessKeyID: keyID, secretAccessKey: secret,
                            sessionToken: environment.value("AWS_SESSION_TOKEN"), label: label)
        }
    }

    /// The environment's key, else the cmux Keychain's.
    private func storedKey(_ provider: AIProvider) throws -> String {
        if let key = provider.apiKeyEnvironmentKeys.lazy.compactMap(environment.value).first { return key }
        if let key = (try? keys.key(for: provider))??.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { return key }
        throw CredentialResolutionError.needsPastedSecret
    }

    /// The Codex CLI's ChatGPT sign-in from `auth.json`, shaped as
    /// `parseCredential` (web/services/coderouter/accounts.ts) requires.
    func codexCredential() throws -> CodexCredential {
        let file = ProviderDetector(environment: environment).codexHome.appendingPathComponent("auth.json")
        guard let tokens = environment.jsonObject(at: file)?["tokens"] as? [String: Any] else {
            throw CredentialResolutionError.incompleteSignIn
        }
        func field(_ name: String) throws -> String {
            guard let value = (tokens[name] as? String)?.nilIfEmpty else { throw CredentialResolutionError.incompleteSignIn }
            return value
        }
        let access = try field("access_token"), idToken = try field("id_token")
        guard let email = JWTClaims(token: idToken)?.email else { throw CredentialResolutionError.incompleteSignIn }
        // The access token's own expiry; the server refreshes from here.
        let expiry = JWTClaims(token: access)?.expiry ?? environment.now.addingTimeInterval(3600)
        return CodexCredential(accessToken: access, refreshToken: try field("refresh_token"), idToken: idToken,
                               accountID: try field("account_id"), email: email,
                               expiresAtMilliseconds: (expiry.timeIntervalSince1970 * 1000).rounded())
    }

    /// One printable token of plausible length (the server validates the rest).
    static func looksLikeKey(_ value: String) -> Bool {
        (16...4096).contains(value.count) && value.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
