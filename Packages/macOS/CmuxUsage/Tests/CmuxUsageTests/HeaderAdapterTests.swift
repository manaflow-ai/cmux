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

    // MARK: Token resolution (synthetic fixtures only — never a real token)

    private static let fakeToken = "sk-ant-oat-FAKE000TESTONLY"

    @Test func envFileParsesExportedToken() {
        let data = Data("export CLAUDE_CODE_OAUTH_TOKEN=\(Self.fakeToken)\n".utf8)
        #expect(ClaudeUsageAdapter.tokenFromEnvFile(data) == Self.fakeToken)
    }

    @Test func envFileParsesBareAndQuotedAmongOtherLines() {
        let bare = Data("FOO=1\nCLAUDE_CODE_OAUTH_TOKEN=\(Self.fakeToken)\nBAR=2\n".utf8)
        #expect(ClaudeUsageAdapter.tokenFromEnvFile(bare) == Self.fakeToken)
        let quoted = Data("export CLAUDE_CODE_OAUTH_TOKEN=\"\(Self.fakeToken)\"\n".utf8)
        #expect(ClaudeUsageAdapter.tokenFromEnvFile(quoted) == Self.fakeToken)
    }

    @Test func envFileStripsTrailingCommentButKeepsBareHash() {
        // ` # …` is a shell comment, not part of the value.
        let commented = Data("export CLAUDE_CODE_OAUTH_TOKEN=\(Self.fakeToken) # my token\n".utf8)
        #expect(ClaudeUsageAdapter.tokenFromEnvFile(commented) == Self.fakeToken)
        // A bare '#' with no preceding space is part of the value (shell semantics).
        let hashy = Data("CLAUDE_CODE_OAUTH_TOKEN=abc#def\n".utf8)
        #expect(ClaudeUsageAdapter.tokenFromEnvFile(hashy) == "abc#def")
    }

    @Test func envFileFailsClosedOnAbsentOrEmpty() {
        #expect(ClaudeUsageAdapter.tokenFromEnvFile(nil) == nil)
        #expect(ClaudeUsageAdapter.tokenFromEnvFile(Data("OTHER=x\n".utf8)) == nil)
        #expect(ClaudeUsageAdapter.tokenFromEnvFile(Data("export CLAUDE_CODE_OAUTH_TOKEN=\n".utf8)) == nil)
        // Oversized input is rejected (size cap).
        let big = Data(("export CLAUDE_CODE_OAUTH_TOKEN=" + String(repeating: "a", count: ClaudeUsageAdapter.maxCredentialFileBytes + 1)).utf8)
        #expect(ClaudeUsageAdapter.tokenFromEnvFile(big) == nil)
    }

    @Test func credentialsJSONParsesAccessToken() {
        let data = Data("{\"claudeAiOauth\":{\"accessToken\":\"\(Self.fakeToken)\"}}".utf8)
        #expect(ClaudeUsageAdapter.tokenFromCredentialsJSON(data) == Self.fakeToken)
    }

    @Test func credentialsJSONFailsClosedOnDrift() {
        #expect(ClaudeUsageAdapter.tokenFromCredentialsJSON(nil) == nil)
        #expect(ClaudeUsageAdapter.tokenFromCredentialsJSON(Data("not json".utf8)) == nil)
        #expect(ClaudeUsageAdapter.tokenFromCredentialsJSON(Data("{\"claudeAiOauth\":{}}".utf8)) == nil)
        #expect(ClaudeUsageAdapter.tokenFromCredentialsJSON(Data("{\"claudeAiOauth\":{\"accessToken\":\"\"}}".utf8)) == nil)
    }

    @Test func resolveTokenPrefersEnvironmentThenFiles() {
        let home = URL(fileURLWithPath: "/fake/home")
        // Environment wins outright.
        let fromEnv = ClaudeUsageAdapter.resolveToken(
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": Self.fakeToken],
            homeDirectory: home,
            readFile: { _ in Data("export CLAUDE_CODE_OAUTH_TOKEN=other".utf8) }
        )
        #expect(fromEnv == Self.fakeToken)

        // No env → credentials.json used before .env.
        let fromCreds = ClaudeUsageAdapter.resolveToken(
            environment: [:],
            homeDirectory: home,
            readFile: { url in
                url.lastPathComponent == ".credentials.json"
                    ? Data("{\"claudeAiOauth\":{\"accessToken\":\"\(Self.fakeToken)\"}}".utf8)
                    : Data("export CLAUDE_CODE_OAUTH_TOKEN=envfile".utf8)
            }
        )
        #expect(fromCreds == Self.fakeToken)

        // No env, no creds file → .env fallback.
        let fromEnvFile = ClaudeUsageAdapter.resolveToken(
            environment: [:],
            homeDirectory: home,
            readFile: { url in
                url.lastPathComponent == ".env"
                    ? Data("export CLAUDE_CODE_OAUTH_TOKEN=\(Self.fakeToken)".utf8)
                    : nil
            }
        )
        #expect(fromEnvFile == Self.fakeToken)

        // Nothing anywhere → nil.
        #expect(ClaudeUsageAdapter.resolveToken(environment: [:], homeDirectory: home, readFile: { _ in nil }) == nil)
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

    @Test func readAuthPicksDeterministicallyAcrossMultipleEntries() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("auth.json")
        // Two issuer entries — selection must be sorted-key deterministic, never
        // dictionary-iteration order ("aaa::1" < "zzz::2").
        try #"{"zzz::2":{"key":"key-Z","user_id":"z"},"aaa::1":{"key":"key-A","user_id":"a"}}"#
            .data(using: .utf8)!.write(to: file)
        let auth = try GrokUsageAdapter.readAuth(fromFileAt: file)
        #expect(auth.key == "key-A")
        #expect(auth.userId == "a")
    }
}
