import Foundation
import Testing
@testable import CmuxUsage

struct CodexUsageAdapterTests {
    /// The real wire shape observed from `backend-api/codex/usage` (ids redacted).
    private static let realResponse = """
    {
      "user_id": "user-REDACTED",
      "account_id": "user-REDACTED",
      "email": "redacted@example.com",
      "plan_type": "plus",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 1,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 509867,
          "reset_at": 1785278338
        },
        "secondary_window": null
      },
      "code_review_rate_limit": null,
      "additional_rate_limits": null,
      "credits": {
        "has_credits": true,
        "unlimited": false,
        "overage_limit_reached": false,
        "balance": 12.5
      }
    }
    """.data(using: .utf8)!

    @Test func parsesPrimaryWindowAndCredits() throws {
        let now = Date(timeIntervalSince1970: 1_784_768_471)
        let snapshot = try CodexUsageAdapter.parseUsage(
            Self.realResponse, fallbackAccountId: "fallback", now: now
        )

        #expect(snapshot.planLabel == "plus")
        #expect(snapshot.account.provider == .codex)

        // Weekly rolling window at 1% used, resetting at the reported epoch.
        let rolling = snapshot.windows.first { window in
            if case .rolling(let seconds) = window.kind { return seconds == 604800 }
            return false
        }
        #expect(rolling != nil)
        #expect(rolling?.usedPercent == 1)
        #expect(rolling?.resetAt == Date(timeIntervalSince1970: 1_785_278_338))

        // Credit balance surfaced as its own window.
        let credits = snapshot.windows.first { $0.kind == .credits }
        #expect(credits?.creditsRemaining == 12.5)

        if case .live(let at) = snapshot.freshness {
            #expect(at == now)
        } else {
            Issue.record("expected .live freshness")
        }
    }

    @Test func fallsBackToResetAfterSecondsWhenNoAbsoluteReset() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let data = """
        {"rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_after_seconds":600}}}
        """.data(using: .utf8)!
        let snapshot = try CodexUsageAdapter.parseUsage(data, fallbackAccountId: "acct", now: now)
        let window = try #require(snapshot.windows.first)
        #expect(window.usedPercent == 40)
        // 1000 + 600s = 1600
        #expect(window.resetAt == Date(timeIntervalSince1970: 1600))
        #expect(snapshot.account.accountId == "acct")
    }

    @Test func failsClosedOnMalformedJSON() {
        let garbage = "not json at all <html>".data(using: .utf8)!
        #expect(throws: UsageAdapterError.malformedResponse) {
            _ = try CodexUsageAdapter.parseUsage(garbage, fallbackAccountId: "x", now: Date())
        }
    }

    @Test func ignoresUnlimitedCredits() throws {
        let data = """
        {"plan_type":"pro","credits":{"has_credits":true,"unlimited":true,"balance":0}}
        """.data(using: .utf8)!
        let snapshot = try CodexUsageAdapter.parseUsage(data, fallbackAccountId: "x", now: Date())
        #expect(snapshot.windows.allSatisfy { $0.kind != .credits })
    }

    @Test func readAuthReadsTokenAndAccount() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-usage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("auth.json")
        try """
        {"auth_mode":"chatgpt","tokens":{"access_token":"tok-abc","account_id":"acct-123"}}
        """.data(using: .utf8)!.write(to: file)

        let auth = try CodexUsageAdapter.readAuth(fromFileAt: file)
        #expect(auth.accessToken == "tok-abc")
        #expect(auth.accountId == "acct-123")
    }

    @Test func readAuthThrowsSignedOutWhenTokenMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-usage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("auth.json")
        try #"{"auth_mode":"chatgpt","tokens":{}}"#.data(using: .utf8)!.write(to: file)

        #expect(throws: UsageAdapterError.signedOut) {
            _ = try CodexUsageAdapter.readAuth(fromFileAt: file)
        }
    }

    @Test func readAuthThrowsNotInstalledWhenFileAbsent() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-usage-absent-\(UUID().uuidString).json")
        #expect(throws: UsageAdapterError.notInstalled) {
            _ = try CodexUsageAdapter.readAuth(fromFileAt: missing)
        }
    }
}
