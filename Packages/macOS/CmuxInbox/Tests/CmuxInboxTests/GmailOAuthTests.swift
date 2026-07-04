import CmuxInbox
import Foundation
import Testing

@Suite("Gmail OAuth credential")
struct GmailOAuthTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func expiryUsesClockSkewHeadroom() {
        let credential = GmailOAuthCredential(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: now.timeIntervalSince1970 + 30,
            clientID: "client",
            clientSecret: nil
        )
        // 30s to expiry is inside the 60s refresh headroom.
        #expect(credential.isExpired(now: now))
        #expect(credential.canRefresh)
    }

    @Test func parseDistinguishesJSONCredentialFromRawToken() throws {
        let credential = GmailOAuthCredential(
            accessToken: "ya29.abc",
            refreshToken: "1//refresh",
            expiresAt: now.timeIntervalSince1970 + 3600,
            clientID: "client",
            clientSecret: "secret"
        )
        let encoded = try credential.encoded()
        #expect(GmailOAuthCredential.parse(from: encoded) == credential)
        #expect(GmailOAuthCredential.parse(from: Data("ya29.rawtoken".utf8)) == nil)
    }

    @Test func parseTokenResponseCapturesRefreshMaterial() throws {
        let json = Data(#"{"access_token":"ya29.new","refresh_token":"1//r","expires_in":3599}"#.utf8)
        let credential = try GmailOAuthCredential.parseTokenResponse(
            data: json,
            clientID: "client",
            clientSecret: nil,
            now: now
        )
        #expect(credential.accessToken == "ya29.new")
        #expect(credential.refreshToken == "1//r")
        #expect(credential.expiresAt == now.timeIntervalSince1970 + 3599)
        #expect(credential.canRefresh)
    }

    @Test func parseTokenResponseSurfacesGoogleError() {
        let json = Data(#"{"error":"invalid_grant","error_description":"Bad Request"}"#.utf8)
        #expect(throws: InboxError.self) {
            _ = try GmailOAuthCredential.parseTokenResponse(data: json, clientID: "c", clientSecret: nil, now: now)
        }
    }

    @Test func refreshResponsePreservesRefreshTokenWhenNotRotated() throws {
        let existing = GmailOAuthCredential(
            accessToken: "old",
            refreshToken: "keep",
            expiresAt: now.timeIntervalSince1970,
            clientID: "client",
            clientSecret: nil
        )
        let json = Data(#"{"access_token":"fresh","expires_in":3600}"#.utf8)
        let updated = try GmailOAuthCredential.parseRefreshResponse(data: json, existing: existing, now: now)
        #expect(updated.accessToken == "fresh")
        #expect(updated.refreshToken == "keep")
        #expect(!updated.isExpired(now: now))
    }

    @Test func pkceChallengeIsDeterministicBase64URL() {
        let challenge = GmailOAuthCredential.codeChallenge(for: "verifier-123")
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
        #expect(!challenge.contains("="))
        #expect(challenge == GmailOAuthCredential.codeChallenge(for: "verifier-123"))
    }

    @Test func authorizationURLRequestsOfflineConsentAndPKCE() throws {
        let url = GmailOAuthCredential.authorizationURL(
            clientID: "client.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:51000/callback",
            state: "state123",
            codeChallenge: "challenge"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(byName["access_type"] == "offline")
        #expect(byName["code_challenge_method"] == "S256")
        #expect(byName["state"] == "state123")
        #expect((byName["scope"] ?? "").contains("gmail.send"))
    }
}
