import Foundation
import Testing
@testable import CmuxNextCodeRouter

/// Callers get `acct_…` handles and redacted displays, never an email.
/// Every value below is invented (someone@example.com and friends).
@Suite(.serialized) struct AccountPrivacyTests {
    /// A home where every detectable source names an email.
    func emailHome() throws -> FixtureHome {
        let home = try FixtureHome()
        try home.writeJSON(".codex/auth.json", codexAuth(email: "someone@example.com", plan: "pro"))
        try home.writeJSON(".claude.json", ["oauthAccount": ["emailAddress": "someone@example.com",
                                                             "organizationName": "someone@example.com's Organization"]])
        try home.writeJSON(".claude/.credentials.json", ["claudeAiOauth": ["accessToken": "fake", "refreshToken": "fake-r", "expiresAt": 1]])
        try home.writeJSON(".gemini/oauth_creds.json", ["refresh_token": "fake"])
        try home.writeJSON(".gemini/google_accounts.json", ["active": "Someone.Else@Example.org", "old": ["older@example.net"]])
        try home.writeJSON("keys/sa-someone@example.com.json", ["type": "service_account", "client_email": "bot@proj.iam.gserviceaccount.com",
                                                                 "quota_project_id": "proj"])
        try home.writeJSON(".config/github-copilot/apps.json", ["github.com:Iv1.fixture": ["user": "octocat", "oauth_token": "fake"]])
        try home.write(".aws/config", "[profile someone@example.com]\nregion = us-west-2\n")
        return home
    }

    func detectAll(_ home: FixtureHome) async -> [ProviderDetection] {
        let env = home.environment([
            "GOOGLE_APPLICATION_CREDENTIALS": home.url.appendingPathComponent("keys/sa-someone@example.com.json").path,
            "AWS_PROFILE": "someone@example.com", "AWS_REGION": "us-west-2",
        ])
        return await ProviderDetector(environment: env).detectAll()
    }

    @Test func detectionNeverCarriesAnEmail() async throws {
        let home = try emailHome()
        let results = await detectAll(home)
        // The fixture is real: these providers found an account.
        for provider in [AIProvider.codex, .claude, .gemini, .vertex, .copilot] {
            let found = try #require(results.first { $0.provider == provider })
            #expect(found.status == .signedIn, "\(provider)")
            #expect(found.account?.handle.hasPrefix("acct_") == true, "\(provider)")
        }
        for detection in results {
            #expect(PrivacyScan.emails(inReflectionOf: detection).isEmpty, "\(detection.provider): \(PrivacyScan.emails(inReflectionOf: detection))")
            let json = try JSONEncoder().encode(detection)
            #expect(PrivacyScan.emails(inJSON: json).isEmpty, "\(detection.provider): \(String(decoding: json, as: UTF8.self))")
        }
        let claude = try #require(results.first { $0.provider == .claude })
        #expect(claude.account?.display == "s…@e… Organization", "an email inside an organization name is shortened")
        #expect(results.first { $0.provider == .bedrock }?.detail == "profile s…@e…")
    }

    @Test func handlesAreStablePerSaltAndOpaque() {
        let a = AccountLabeler(salt: fixtureSalt), b = AccountLabeler(salt: fixtureSalt)
        let handle = a.handle(namespace: "codex", identity: "someone@example.com")
        #expect(handle == b.handle(namespace: "codex", identity: "someone@example.com"))
        #expect(handle == a.handle(namespace: "codex", identity: "  Someone@Example.COM \n"), "identities are normalized")
        #expect(handle != a.handle(namespace: "claude", identity: "someone@example.com"), "the provider is part of the handle")
        #expect(handle != a.handle(namespace: "codex", identity: "other@example.com"))
        let otherSalt = AccountLabeler(salt: Data(repeating: 0xA5, count: 32))
        #expect(handle != otherSalt.handle(namespace: "codex", identity: "someone@example.com"), "another user gets another handle")
        // acct_ + 26 base32 characters (128 bits), lowercase, no padding.
        #expect(handle.wholeMatch(of: #/acct_[a-z2-7]{26}/#) != nil, "\(handle)")
        #expect(!handle.contains("someone"))
        #expect(AccountLabeler.base32(Array("foobar".utf8)) == "mzxw6ytboi", "RFC 4648 test vector, lowercase, unpadded")
        #expect(PrivacyScan.emails(inReflectionOf: a).isEmpty)
        #expect(!"\(a)".contains(fixtureSalt.base64EncodedString()))
    }

    @Test func storeUsesTheProvidedSaltAndFallsBackToAnEphemeralOne() async {
        let store = AccountLabelerStore(provider: FixedSalt(bytes: fixtureSalt))
        let fromStore = await store.labeler().handle(namespace: "codex", identity: "someone@example.com")
        #expect(fromStore == fixtureLabeler.handle(namespace: "codex", identity: "someone@example.com"))
        let storeEphemeral = await store.usesEphemeralSalt
        #expect(!storeEphemeral)
        struct Broken: AccountLabelSaltProviding {
            struct Failure: Error {}
            func salt() throws -> Data { throw Failure() }
        }
        let broken = AccountLabelerStore(provider: Broken())
        let first = await broken.labeler().handle(namespace: "codex", identity: "someone@example.com")
        let second = await broken.labeler().handle(namespace: "codex", identity: "someone@example.com")
        let brokenEphemeral = await broken.usesEphemeralSalt
        #expect(brokenEphemeral)
        let failure = await broken.saltFailure
        #expect(failure?.isEmpty == false, "the failure is kept for the log")
        #expect(first.hasPrefix("acct_"))
        #expect(first == second, "stable within the process")
    }

    @Test func displaysNeverMatchAnEmail() throws {
        #expect(EmailRedaction.redact(identity: "someone@example.com") == "s…@e…")
        #expect(EmailRedaction.redact(identity: "octocat") == "o…")
        #expect(EmailRedaction.redactEmails(in: "work (someone@example.com)") == "work (s…@e…)")
        #expect(AccountLabel(handle: "acct_x", display: "someone@example.com").display == "s…@e…", "the initializer redacts")
        let decoded = try JSONDecoder().decode(AccountLabel.self, from: Data(#"{"account":"acct_x","label":"someone@example.com"}"#.utf8))
        #expect(decoded.display == "s…@e…", "decoding redacts too")
        #expect(PrivacyScan.emails(inJSON: try JSONEncoder().encode(decoded)).isEmpty)
    }

    @Test func codexCredentialDescriptionHasNoEmail() throws {
        let home = try FixtureHome()
        try home.writeJSON(".codex/auth.json", codexAuth(email: "someone@example.com"))
        let credential = try CredentialResolver(environment: home.environment(), keys: FakeKeyStore()).credential(for: .codex, pasted: nil)
        guard case .codex(let codex) = credential else { Issue.record("expected codex"); return }
        #expect(PrivacyScan.emails(in: codex.description).isEmpty)
        #expect(PrivacyScan.emails(in: codex.debugDescription).isEmpty)
        #expect(PrivacyScan.emails(inReflectionOf: codex).isEmpty, "dump and the debugger show no field")
        #expect(PrivacyScan.emails(inReflectionOf: credential).isEmpty)
        // The one HTTPS request still carries it: the server needs it.
        #expect(codex.body["email"] as? String == "someone@example.com")
    }
}

/// The CodeRouter client boundary: typed lists and the raw replies the
/// `coderouter.*` socket methods pass through. An extension of the
/// serialized client suite, because the fake server is shared state.
extension CodeRouterClientTests {
    static let nativeReply = #"""
    {"teamId":"team-1","accounts":[
      {"id":"a1","provider":"codex","label":"someone@example.com","providerAccountId":"x-1","state":"active","visibility":"private"},
      {"id":"a2","provider":"openrouter-apikey","label":"work (other@example.com)","providerAccountId":"sk-or-v1-…abcd","state":"active"},
      {"id":"a3","provider":"openai-apikey","label":"sk-…wxyz","providerAccountId":"sk-…wxyz","state":"active"}]}
    """#
    static let claudeReply = #"""
    {"teamId":"team-1","accounts":[
      {"id":"c1","kind":"anthropic_oauth","label":"","identifier":"sk-ant-oat01-…abcd","state":"active"},
      {"id":"c2","kind":"anthropic_api_key","label":"someone@example.com","identifier":"sk-ant-api03-…wxyz","state":"active"}]}
    """#

    @Test func typedListCarriesLabelsOnly() async throws {
        FakeCodeRouter.reset(["GET /api/coderouter/accounts": (200, Self.nativeReply), "GET /api/coderouter/claude-upstream": (200, Self.claudeReply)])
        let accounts = try await client.linkedAccounts()
        #expect(accounts.count == 5)
        for account in accounts {
            #expect(PrivacyScan.emails(inReflectionOf: account).isEmpty, "\(account)")
            #expect(account.account.handle.hasPrefix("acct_"))
        }
        #expect(accounts[0].label == "s…@e…")
        #expect(accounts[1].label == "work (o…@e…)")
        #expect(accounts[2].label == "sk-…wxyz", "a masked key is kept")
        // A Codex email has the same handle here as in local detection.
        #expect(accounts[0].account.handle == fixtureLabeler.local(.codex, identity: "someone@example.com").handle)
    }

    @Test func passthroughRepliesAreRedactedWithMatchingHandles() async throws {
        FakeCodeRouter.reset(["GET /api/coderouter/accounts": (200, Self.nativeReply), "GET /api/coderouter/claude-upstream": (200, Self.claudeReply)])
        let typed = try await client.linkedAccounts()
        let native = try await client.request("GET", "/api/coderouter/accounts")
        let claude = try await client.request("GET", "/api/coderouter/claude-upstream")
        #expect(PrivacyScan.emails(inJSON: native).isEmpty, "\(String(decoding: native, as: UTF8.self))")
        #expect(PrivacyScan.emails(inJSON: claude).isEmpty, "\(String(decoding: claude, as: UTF8.self))")
        func rows(_ data: Data) throws -> [[String: Any]] {
            try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["accounts"] as? [[String: Any]])
        }
        let rows = try rows(native) + rows(claude)
        #expect(rows.count == typed.count)
        for (row, account) in zip(rows, typed) {
            #expect(row["id"] as? String == account.id)
            #expect(row["account"] as? String == account.account.handle, "socket and typed handles agree")
        }
        #expect(rows[3]["label"] as? String == "", "an empty label stays empty for the CLI")
        #expect(rows[3]["identifier"] as? String == "sk-ant-oat01-…abcd")
        #expect(rows[4]["label"] as? String == "s…@e…")
        #expect(rows.allSatisfy { $0["providerAccountId"] == nil && $0["providerUserId"] == nil }, "provider ids are dropped")
    }

    @Test func serverErrorsAndOtherRepliesAreRedacted() async throws {
        FakeCodeRouter.reset([
            "POST /api/coderouter/accounts": (409, #"{"error":"duplicate","message":"someone@example.com is already linked"}"#),
            "GET /api/coderouter/vm-usage/team": (200, #"{"machines":[{"id":"m1","provider":"freestyle","label":"box","owner":"someone@example.com","displayName":"box"}]}"#),
        ])
        do {
            _ = try await client.request("POST", "/api/coderouter/accounts", body: ["provider": "codex"])
            Issue.record("expected a failure")
        } catch let error as CodeRouterError {
            #expect(PrivacyScan.emails(in: error.description).isEmpty, "\(error)")
        }
        let machines = try await client.request("GET", "/api/coderouter/vm-usage/team")
        #expect(PrivacyScan.emails(inJSON: machines).isEmpty)
        #expect(String(decoding: machines, as: UTF8.self).contains("box"))
        #expect(!String(decoding: machines, as: UTF8.self).contains("acct_"), "only account endpoints get handles")
    }
}
