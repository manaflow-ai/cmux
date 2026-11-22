import Foundation
import Testing
@testable import CmuxNextCodeRouter

/// The CodeRouter client boundary: typed lists and the raw replies the
/// `coderouter.*` socket methods pass through. An extension of the
/// serialized client suite, because the fake server is shared state.
extension CodeRouterClientTests {
    static let nativeReply = #"""
    {"teamId":"team-1","accounts":[
      {"id":"a1","provider":"codex","label":"someone@example.com","providerAccountId":"acct-fixture","providerUserId":"user-fixture","state":"active","visibility":"private"},
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
        // A Codex sign-in has the same handle here as in local detection (workspace + user ids).
        #expect(accounts[0].account.handle == codexHandle())
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
