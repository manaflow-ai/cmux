import Foundation
import Testing
@testable import CmuxNextCodeRouter

/// Email forms a naive pattern misses. Every value is invented.
let hostileEmails = [
    "user@bücher.de", #""john doe"@example.com"#, "someone%40example.com", "Someone%40Example.com", "someone＠example.com",
    "user@[10.0.0.1]", "u@exa_mple.com", "jörg@example.com", "someone@example.com",
]

@Suite struct HostileEmailRedactionTests {
    @Test func everyFormIsShortened() {
        for email in hostileEmails {
            for text in [email, "work (\(email))", "\(email)'s Organization", "~/keys/\(email).json", "a \(email) b \(email)"] {
                let redacted = EmailRedaction.redactEmails(in: text)
                #expect(PrivacyScan.emails(in: redacted).isEmpty, "\(text) -> \(redacted)")
                #expect(EmailRedaction.redactEmails(in: redacted) == redacted, "idempotent: \(redacted)")
            }
            let identity = EmailRedaction.redact(identity: email)
            #expect(PrivacyScan.emails(in: identity).isEmpty, "\(email) -> \(identity)")
            #expect(identity.count <= 5, "at most one character on each side: \(identity)")
            let label = fixtureLabeler.local(.gemini, identity: email)
            #expect(PrivacyScan.emails(inReflectionOf: label).isEmpty, "\(label)")
            #expect(PrivacyScan.emails(inJSON: (try? JSONEncoder().encode(label)) ?? Data()).isEmpty)
        }
        #expect(EmailRedaction.redact(identity: "jörg@example.com") == "j…@e…", "no second letter of a non-ASCII local part")
        #expect(EmailRedaction.redactEmails(in: #"by "john doe"@example.com today"#) == "by j…@e… today")
        #expect(EmailRedaction.redact(identity: "user@[10.0.0.1]") == "u…@1…")
    }

    @Test func handlesAreNFCNormalizedAndValidated() throws {
        let composed = fixtureLabeler.handle(namespace: "codex", identity: "jörg@example.com")
        let decomposed = fixtureLabeler.handle(namespace: "codex", identity: "jo\u{0308}rg@EXAMPLE.com")
        #expect(composed == decomposed)
        #expect(AccountLabel.isValidHandle(composed))
        for bad in ["acct_", "acct_ABC", "acct_ab1", "user_abc", "acct_ab-c"] { #expect(!AccountLabel.isValidHandle(bad), "\(bad)") }
        #expect(AccountLabel.isValidHandle(AccountLabel.demo("codex", display: "pro").handle))
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AccountLabel.self, from: Data(#"{"account":"someone@example.com","label":"x"}"#.utf8))
        }
    }

    @Test func detectionShortensEveryForm() async throws {
        let home = try FixtureHome()
        try home.writeJSON(".codex/auth.json", codexAuth(email: "jörg@example.com", plan: ""))
        try home.writeJSON(".claude.json", ["oauthAccount": ["emailAddress": #""john doe"@example.com"#, "organizationName": "user@bücher.de"]])
        try home.writeJSON(".claude/.credentials.json", ["claudeAiOauth": ["accessToken": "fake", "refreshToken": "fake-r", "expiresAt": 1]])
        try home.writeJSON(".gemini/oauth_creds.json", ["refresh_token": "fake"])
        try home.writeJSON(".gemini/google_accounts.json", ["active": "someone＠example.com"])
        try home.writeJSON("keys/someone%40example.com.json", ["type": "service_account", "client_email": "someone%40example.com"])
        // hosts.json (the older Copilot plugin layout), with an email-shaped login.
        try home.writeJSON(".config/github-copilot/hosts.json", ["github.com": ["user": "user@[10.0.0.1]", "oauth_token": "fake"]])
        try home.write(".aws/config", "[profile u@exa_mple.com]\nregion = us-west-2\n")
        let env = home.environment(["GOOGLE_APPLICATION_CREDENTIALS": home.url.appendingPathComponent("keys/someone%40example.com.json").path,
                                    "AWS_PROFILE": "u@exa_mple.com", "AWS_REGION": "Someone%40Example.com"])
        let results = await ProviderDetector(environment: env).detectAll()
        for provider in [AIProvider.codex, .claude, .gemini, .vertex, .copilot] {
            #expect(results.first { $0.provider == provider }?.account != nil, "\(provider) found an account")
        }
        for detection in results {
            #expect(PrivacyScan.emails(inReflectionOf: detection).isEmpty, "\(detection.provider): \(detection)")
            #expect(PrivacyScan.emails(inJSON: try JSONEncoder().encode(detection)).isEmpty, "\(detection.provider)")
        }
        #expect(results.first { $0.provider == .codex }?.account?.display == "j…@e…")
        #expect(results.first { $0.provider == .copilot }?.sources == [.file("~/.config/github-copilot/hosts.json")])
    }
}

/// Server rows with hostile labels, ids and keys. Serialized with the
/// client suite (the fake server is shared state).
extension CodeRouterClientTests {
    static func row(_ id: String, label: String, accountID: String? = nil, extra: String = "") -> String {
        let accountField = accountID.map { #","providerAccountId":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","provider":"openrouter-apikey","label":"\#(label)"\#(accountField),"state":"active"\#(extra)}"#
    }

    @Test func hostileServerLabelsAndIdsAreRedacted() async throws {
        let native = hostileEmails.enumerated().map { index, email in
            Self.row("h\(index)", label: email.replacingOccurrences(of: "\"", with: "\\\""), accountID: "id-\(email.replacingOccurrences(of: "\"", with: "\\\""))")
        }
        let claude = #"{"accounts":[{"id":"c9","kind":"anthropic_oauth","label":"","identifier":"jörg@example.com","state":"active"}]}"#
        FakeCodeRouter.reset([
            "GET /api/coderouter/accounts": (200, #"{"accounts":["# + native.joined(separator: ",") + #"],"byEmail":{"someone@example.com":1}}"#),
            "GET /api/coderouter/claude-upstream": (200, claude),
        ])
        let typed = try await client.linkedAccounts()
        #expect(typed.count == hostileEmails.count + 1)
        for account in typed { #expect(PrivacyScan.emails(inReflectionOf: account).isEmpty, "\(account)") }
        let reply = try await client.request("GET", "/api/coderouter/accounts")
        #expect(PrivacyScan.emails(inJSON: reply).isEmpty, "\(String(decoding: reply, as: UTF8.self))")
        let object = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let keys = try #require(object["byEmail"] as? [String: Any]).keys
        #expect(keys.allSatisfy { AccountLabel.isValidHandle($0) }, "an email key becomes its handle")
        let upstream = try await client.request("GET", "/api/coderouter/claude-upstream")
        #expect(PrivacyScan.emails(inJSON: upstream).isEmpty, "an email in identifier is shortened")
    }

    @Test func renamingKeepsTheHandleAndSameLabelsStayDistinct() async throws {
        func handles(_ rows: [String]) async throws -> [String] {
            FakeCodeRouter.reset(["GET /api/coderouter/accounts": (200, #"{"accounts":["# + rows.joined(separator: ",") + "]}"),
                                  "GET /api/coderouter/claude-upstream": (200, #"{"accounts":[]}"#)])
            return try await client.linkedAccounts().map(\.account.handle)
        }
        let before = try await handles([Self.row("k1", label: "work", accountID: "sk-or-v1-…aaaa"), Self.row("k2", label: "work", accountID: "sk-or-v1-…bbbb")])
        let renamed = try await handles([Self.row("k1", label: "home", accountID: "sk-or-v1-…aaaa"), Self.row("k2", label: "work", accountID: "sk-or-v1-…bbbb")])
        #expect(before[0] != before[1], "two accounts with the same label get different handles")
        #expect(before == renamed, "renaming keeps the handle")
        let unlabeled = try await handles([Self.row("k3", label: ""), Self.row("k4", label: "")])
        #expect(unlabeled[0] != unlabeled[1], "rows without a label or id fall back to the row id")
        // An existing server `account` field is never overwritten.
        FakeCodeRouter.reset(["GET /api/coderouter/accounts": (200, #"{"accounts":["# + Self.row("k5", label: "work", extra: #","account":"server-value""#) + "]}")])
        let reply = try await client.request("GET", "/api/coderouter/accounts")
        let rows = try #require((try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["accounts"] as? [[String: Any]])
        #expect(rows.first?["account"] as? String == "server-value")
    }

    @Test func nonJSONRepliesAndErrorCodesAreRedacted() async throws {
        FakeCodeRouter.reset([
            "GET /api/coderouter/vm-usage/team": (200, "plain text for someone＠example.com and jörg@example.com"),
            "POST /api/coderouter/claude-upstream": (400, #"{"error":"exists:someone@example.com","message":"user%40example.com"}"#),
        ])
        let text = try await client.request("GET", "/api/coderouter/vm-usage/team")
        #expect(PrivacyScan.emails(inJSON: text).isEmpty, "\(String(decoding: text, as: UTF8.self))")
        do {
            _ = try await client.request("POST", "/api/coderouter/claude-upstream", body: ["kind": "anthropic_oauth"])
            Issue.record("expected a failure")
        } catch let error as CodeRouterError {
            guard case .http(_, let code, let message) = error else { Issue.record("\(error)"); return }
            #expect(PrivacyScan.emails(in: code ?? "").isEmpty, "\(code ?? "")")
            #expect(PrivacyScan.emails(in: message ?? "").isEmpty, "\(message ?? "")")
        }
    }
}
