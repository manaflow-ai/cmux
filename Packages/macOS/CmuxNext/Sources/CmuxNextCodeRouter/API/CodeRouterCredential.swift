import Foundation

/// A Codex ChatGPT sign-in for `POST /api/coderouter/accounts` (`parseCredential`).
/// `CustomStringConvertible` is redacted so the tokens and the email never
/// reach a log. The email is only in ``body``, which the server needs and
/// which lives for the one HTTPS request.
public struct CodexCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let accountID: String
    let email: String
    /// Milliseconds since 1970 (the server's unit).
    let expiresAtMilliseconds: Double

    public var description: String { "CodexCredential(<redacted>)" }
    public var debugDescription: String { description }
    /// `dump` and the debugger show no field.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    var body: [String: any Sendable] {
        ["provider": "codex", "accessToken": accessToken, "refreshToken": refreshToken, "idToken": idToken,
         "accountId": accountID, "email": email, "expiresAt": expiresAtMilliseconds]
    }
}

/// What Connect sends to CodeRouter. Redacted in descriptions.
public enum CodeRouterCredential: Sendable, CustomStringConvertible, CustomReflectable {
    case codex(CodexCredential)
    case apiKey(serverProvider: String, key: String, label: String?)
    case claudeOAuthToken(String, label: String?)
    case anthropicAPIKey(String, label: String?)
    case bedrock(region: String, accessKeyID: String, secretAccessKey: String, sessionToken: String?, label: String?)

    public var description: String {
        switch self {
        case .codex(let credential): credential.description
        case .apiKey(let provider, _, _): "apiKey(\(provider), <redacted>)"
        case .claudeOAuthToken: "claudeOAuthToken(<redacted>)"
        case .anthropicAPIKey: "anthropicAPIKey(<redacted>)"
        case .bedrock(let region, _, _, _, _): "bedrock(\(region), <redacted>)"
        }
    }

    /// `dump` and the debugger show the description only.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }

    var family: LinkedAccount.Family {
        switch self {
        case .codex, .apiKey: .native
        case .claudeOAuthToken, .anthropicAPIKey, .bedrock: .claude
        }
    }

    /// The JSON body of the add route. New accounts are private to the
    /// importer unless shared from the dashboard (README "VM team and account access").
    var body: [String: any Sendable] {
        var body: [String: any Sendable]
        var label: String?
        switch self {
        case .codex(let credential): body = credential.body
        case .apiKey(let provider, let key, let name): body = ["provider": provider, "apiKey": key]; label = name
        case .claudeOAuthToken(let token, let name): body = ["kind": "anthropic_oauth", "token": token]; label = name
        case .anthropicAPIKey(let key, let name): body = ["kind": "anthropic_api_key", "apiKey": key]; label = name
        case .bedrock(let region, let keyID, let secret, let session, let name):
            body = ["kind": "bedrock", "region": region, "accessKeyId": keyID, "secretAccessKey": secret]
            if let session { body["sessionToken"] = session }
            label = name
        }
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { body["label"] = label }
        body["visibility"] = "private"
        return body
    }
}
