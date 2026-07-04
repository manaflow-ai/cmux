public import Foundation
import CryptoKit

/// Gmail OAuth credential stored in the token vault.
///
/// The vault accepts either a raw access-token string (legacy paste flow) or
/// this JSON credential produced by the in-app Google sign-in. The credential
/// carries its own refresh material so the connector can renew access tokens
/// autonomously: link once, sync forever.
public struct GmailOAuthCredential: Codable, Equatable, Sendable {
    public var kind: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Double
    public var clientID: String
    public var clientSecret: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Double,
        clientID: String,
        clientSecret: String?
    ) {
        self.kind = "gmail_oauth"
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Parses vault bytes; nil means the bytes are a legacy raw access token.
    public static func parse(from data: Data) -> GmailOAuthCredential? {
        guard let credential = try? JSONDecoder().decode(GmailOAuthCredential.self, from: data),
              credential.kind == "gmail_oauth", !credential.accessToken.isEmpty else { return nil }
        return credential
    }

    /// Serialized vault representation.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Whether the access token needs a refresh, with clock-skew headroom.
    public func isExpired(now: Date) -> Bool {
        now.timeIntervalSince1970 >= (expiresAt - 60)
    }

    /// Whether autonomous renewal is possible.
    public var canRefresh: Bool {
        !(refreshToken ?? "").isEmpty && !clientID.isEmpty
    }

    // MARK: - OAuth requests (pure builders, unit-testable)

    public static let defaultScopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
    ]

    /// Builds the browser authorization URL for the loopback flow (RFC 8252 + PKCE).
    public static func authorizationURL(
        clientID: String,
        redirectURI: String,
        scopes: [String] = defaultScopes,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    /// PKCE S256 challenge for a verifier.
    public static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded()
    }

    /// Exchanges an authorization code for tokens.
    public static func tokenExchangeRequest(
        clientID: String,
        clientSecret: String?,
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) -> URLRequest {
        var fields = [
            "client_id": clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        if let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        return formPOST(url: "https://oauth2.googleapis.com/token", fields: fields)
    }

    /// Renews the access token from the refresh token.
    public static func refreshRequest(credential: GmailOAuthCredential) throws -> URLRequest {
        guard credential.canRefresh, let refreshToken = credential.refreshToken else {
            throw InboxError.tokenUnavailable(.gmail, "refresh")
        }
        var fields = [
            "client_id": credential.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        if let secret = credential.clientSecret, !secret.isEmpty { fields["client_secret"] = secret }
        return formPOST(url: "https://oauth2.googleapis.com/token", fields: fields)
    }

    /// Parses a token-endpoint response for the initial exchange.
    public static func parseTokenResponse(
        data: Data,
        clientID: String,
        clientSecret: String?,
        now: Date
    ) throws -> GmailOAuthCredential {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            let message = (object["error_description"] as? String) ?? (object["error"] as? String) ?? "Google token exchange failed"
            throw InboxError.connectorUnavailable(message)
        }
        let expiresIn = (object["expires_in"] as? Double) ?? 3600
        return GmailOAuthCredential(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            expiresAt: now.timeIntervalSince1970 + expiresIn,
            clientID: clientID,
            clientSecret: clientSecret
        )
    }

    /// Applies a refresh response to an existing credential.
    public static func parseRefreshResponse(
        data: Data,
        existing: GmailOAuthCredential,
        now: Date
    ) throws -> GmailOAuthCredential {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            let message = (object["error_description"] as? String) ?? (object["error"] as? String) ?? "Google token refresh failed"
            throw InboxError.tokenUnavailable(.gmail, message)
        }
        var updated = existing
        updated.accessToken = accessToken
        updated.expiresAt = now.timeIntervalSince1970 + ((object["expires_in"] as? Double) ?? 3600)
        if let rotated = object["refresh_token"] as? String, !rotated.isEmpty {
            updated.refreshToken = rotated
        }
        return updated
    }

    private static func formPOST(url: String, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return request
    }
}

public extension Data {
    /// Base64url without padding, as required by PKCE.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
