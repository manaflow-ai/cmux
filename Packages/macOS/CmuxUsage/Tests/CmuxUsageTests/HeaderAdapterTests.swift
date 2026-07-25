import Foundation
import Testing
@testable import CmuxUsage

private func approx(_ a: Double?, _ b: Double, tol: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a - b) < tol
}

struct ClaudeUsageAdapterTests {
    /// Real `anthropic-ratelimit-unified-*` headers captured from a live /v1/messages call.
    private static let headers: [String: String] = [
        "anthropic-ratelimit-unified-status": "allowed",
        "anthropic-ratelimit-unified-5h-status": "allowed",
        "anthropic-ratelimit-unified-5h-reset": "1784947200",
        "anthropic-ratelimit-unified-5h-utilization": "0.07",
        "anthropic-ratelimit-unified-7d-status": "allowed",
        "anthropic-ratelimit-unified-7d-reset": "1785200400",
        "anthropic-ratelimit-unified-7d-utilization": "0.59",
        "anthropic-organization-id": "org-abc",
    ]

    @Test func parsesFiveHourAndWeeklyWindows() throws {
        let now = Date(timeIntervalSince1970: 1_784_940_000)
        let snap = try ClaudeUsageAdapter.parseUsage(headers: Self.headers, now: now)
        #expect(snap.account.provider == .claude)
        #expect(snap.account.accountId == "org-abc")
        #expect(snap.windows.count == 2)

        let fiveHour = try #require(snap.windows.first { $0.kind == .rolling(seconds: 18000) })
        #expect(approx(fiveHour.usedPercent, 7.0))
        #expect(fiveHour.resetAt == Date(timeIntervalSince1970: 1_784_947_200))

        let weekly = try #require(snap.windows.first { $0.kind == .rolling(seconds: 604800) })
        #expect(approx(weekly.usedPercent, 59.0))
        #expect(weekly.resetAt == Date(timeIntervalSince1970: 1_785_200_400))
    }

    @Test func failsClosedWhenNoUnifiedHeaders() {
        #expect(throws: UsageAdapterError.malformedResponse) {
            _ = try ClaudeUsageAdapter.parseUsage(headers: ["content-type": "application/json"], now: Date())
        }
    }

    @Test func defaultsAccountWhenOrgHeaderAbsent() throws {
        var h = Self.headers
        h["anthropic-organization-id"] = nil
        let snap = try ClaudeUsageAdapter.parseUsage(headers: h, now: Date())
        #expect(snap.account.accountId == "default")
    }
}

struct GrokUsageAdapterTests {
    /// Real `x-ratelimit-*` headers captured from a live /v1/responses call.
    private static func headers(remainingTokens: String, limitTokens: String) -> [String: String] {
        [
            "x-ratelimit-limit-tokens": limitTokens,
            "x-ratelimit-remaining-tokens": remainingTokens,
            "x-ratelimit-limit-requests": "8300",
            "x-ratelimit-remaining-requests": "8300",
        ]
    }

    @Test func parsesTokenAndRequestQuotasFull() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let snap = try GrokUsageAdapter.parseUsage(
            headers: Self.headers(remainingTokens: "53000000", limitTokens: "53000000"), now: now
        )
        #expect(snap.account.provider == .grok)
        #expect(snap.windows.count == 2)

        let tokens = try #require(snap.windows.first { $0.kind == .quota(unit: "tokens") })
        #expect(approx(tokens.usedPercent, 0.0))
        #expect(tokens.remaining == 53_000_000)
        #expect(tokens.limit == 53_000_000)

        let requests = try #require(snap.windows.first { $0.kind == .quota(unit: "requests") })
        #expect(approx(requests.usedPercent, 0.0))
    }

    @Test func computesUsedPercentFromRemaining() throws {
        let snap = try GrokUsageAdapter.parseUsage(
            headers: Self.headers(remainingTokens: "26500000", limitTokens: "53000000"), now: Date()
        )
        let tokens = try #require(snap.windows.first { $0.kind == .quota(unit: "tokens") })
        #expect(approx(tokens.usedPercent, 50.0))
    }

    @Test func failsClosedWhenNoRateLimitHeaders() {
        #expect(throws: UsageAdapterError.malformedResponse) {
            _ = try GrokUsageAdapter.parseUsage(headers: ["date": "now"], now: Date())
        }
    }

    @Test func readAuthExtractsKeyFromIssuerKeyedEntry() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("auth.json")
        try """
        {"https://auth.x.ai::abc":{"key":"grok-key-xyz","user_id":"u-123","auth_mode":"session"}}
        """.data(using: .utf8)!.write(to: file)

        let auth = try GrokUsageAdapter.readAuth(fromFileAt: file)
        #expect(auth.key == "grok-key-xyz")
        #expect(auth.userId == "u-123")
    }
}
