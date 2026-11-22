import Foundation
import Testing
@testable import CmuxNextCodeRouter

/// Email forms a naive pattern misses. Every value is invented.
let hostileEmails = [
    "user@bücher.de", #""john doe"@example.com"#, "someone%40example.com", "Someone%40Example.com", "someone＠example.com",
    "user@[10.0.0.1]", "u@exa_mple.com", "jörg@example.com", "someone@example.com",
    "someone@\u{0301}example.com", "someone%2540example.com", "someone\u{FE6B}example.com",
]

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
        // A server `account` field moves to `server_account`.
        FakeCodeRouter.reset(["GET /api/coderouter/accounts": (200, #"{"accounts":["# + Self.row("k5", label: "work", extra: #","account":"server-value""#) + "]}")])
        let reply = try await client.request("GET", "/api/coderouter/accounts")
        let rows = try #require((try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["accounts"] as? [[String: Any]])
        #expect(AccountLabel.isValidHandle(rows.first?["account"] as? String ?? ""), "the handle always wins")
        #expect(rows.first?["server_account"] as? String == "server-value", "the server value moves aside")
    }

    @Test func nonJSONRepliesAndErrorCodesAreRedacted() async throws {
        FakeCodeRouter.reset([
            "GET /api/coderouter/vm-usage/team": (200, #"plain text for someone＠example.com, jörg@example.com, a&#64;example.com, b&#x40;example.com and c\u0040example.com"#),
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
