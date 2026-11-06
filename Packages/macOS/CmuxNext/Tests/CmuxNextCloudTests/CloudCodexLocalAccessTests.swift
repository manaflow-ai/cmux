import Foundation
import Testing
@testable import CmuxNextCloud

/// The Mac's own Codex `auth.json`, read for its access token only (fixtures; never a real home).
struct CloudCodexLocalAccessTests {
    static func jwt(_ claims: [String: Any]) -> String {
        func part(_ object: [String: Any]) -> String {
            (try? JSONSerialization.data(withJSONObject: object))!.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return part(["alg": "none"]) + "." + part(claims) + ".sig"
    }

    static func auth(access: String, account: String? = "acct", key: Any = NSNull(), mode: String? = "chatgpt") -> Data {
        var tokens: [String: Any] = ["access_token": access, "refresh_token": "fixture-refresh", "id_token": jwt([:])]
        if let account { tokens["account_id"] = account }
        var root: [String: Any] = ["OPENAI_API_KEY": key, "tokens": tokens]
        if let mode { root["auth_mode"] = mode }
        return (try? JSONSerialization.data(withJSONObject: root))!
    }

    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func givesOnlyTheAccessTokenAccountAndExpiry() throws {
        let access = Self.jwt(["exp": now.timeIntervalSince1970 + 3600])
        let grant = try #require(CloudCodexLocalAccess.grant(authJSON: Self.auth(access: access), now: now))
        #expect(grant.accessToken == access && grant.chatgptAccountID == "acct")
        #expect(grant.expiresAt == now.addingTimeInterval(3600))
    }

    @Test func readsAnIntegerExpiry() throws {
        let access = Self.jwt(["exp": Int(now.timeIntervalSince1970) + 3600])
        #expect(CloudCodexLocalAccess.grant(authJSON: Self.auth(access: access), now: now)?.expiresAt == now.addingTimeInterval(3600))
    }

    @Test func readsTheAccountFromTheTokenWhenTheFileHasNone() throws {
        let access = Self.jwt(["exp": now.timeIntervalSince1970 + 3600, "https://api.openai.com/auth": ["chatgpt_account_id": "from-claim"]])
        #expect(CloudCodexLocalAccess.grant(authJSON: Self.auth(access: access, account: nil), now: now)?.chatgptAccountID == "from-claim")
        let topLevel = Self.jwt(["exp": now.timeIntervalSince1970 + 3600, "chatgpt_account_id": "top"])
        #expect(CloudCodexLocalAccess.grant(authJSON: Self.auth(access: topLevel, account: nil), now: now)?.chatgptAccountID == "top")
    }

    @Test func offersNothingNearItsEndForAnAPIKeyOrAnotherMode() {
        let soon = Self.jwt(["exp": now.timeIntervalSince1970 + 60])
        #expect(CloudCodexLocalAccess.grant(authJSON: Self.auth(access: soon), now: now) == nil)
        let fine = Self.jwt(["exp": now.timeIntervalSince1970 + 3600])
        #expect(CloudCodexLocalAccess.grant(authJSON: Self.auth(access: fine, key: "sk-fixture"), now: now) == nil)
        #expect(CloudCodexLocalAccess.grant(authJSON: Self.auth(access: fine, mode: "apikey"), now: now) == nil)
        #expect(CloudCodexLocalAccess.grant(authJSON: Data("not json".utf8), now: now) == nil)
        let far = Self.jwt(["exp": 1e300])
        #expect(CloudCodexLocalAccess.grant(authJSON: Self.auth(access: far), now: now) == nil)
    }

    @Test func readsOnlyAPrivateFileInTheFileStore() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("auth.json")
        let access = Self.jwt(["exp": Date().timeIntervalSince1970 + 3600])
        try Self.auth(access: access).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(CloudCodexLocalAccess(home: home).read() == nil) // readable by others: not Codex's own file
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(CloudCodexLocalAccess(home: home).read()?.accessToken == access)
        let config = home.appendingPathComponent("config.toml")
        try Data("cli_auth_credentials_store = \"keyring\"\n".utf8).write(to: config)
        #expect(CloudCodexLocalAccess(home: home).read() == nil) // the Keychain is Codex's own
        try Data("cli_auth_credentials_store = \"file\" # default\n".utf8).write(to: config)
        #expect(CloudCodexLocalAccess(home: home).read()?.accessToken == access)
    }

    @Test func homeFollowsCodexHome() {
        let user = URL(fileURLWithPath: "/Users/fixture")
        #expect(CloudCodexLocalAccess.home(environment: [:], userHome: user).path == "/Users/fixture/.codex")
        #expect(CloudCodexLocalAccess.home(environment: ["CODEX_HOME": "~/alt"], userHome: user).path == "/Users/fixture/alt")
        #expect(CloudCodexLocalAccess.home(environment: ["CODEX_HOME": "relative"], userHome: user).path == "/Users/fixture/.codex")
    }
}
