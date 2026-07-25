public import Foundation

/// Claude usage adapter.
///
/// Claude Code authenticates via the long-lived, non-rotating `CLAUDE_CODE_OAUTH_TOKEN`
/// (a `claude setup-token`), which is `user:inference`-scoped. The dedicated
/// `/api/oauth/usage` endpoint requires `user:profile` (403 for this token), but the
/// rolling-window utilization rides on the **`anthropic-ratelimit-unified-*` response
/// headers of a real `/v1/messages` call** — which only needs `user:inference`. So this
/// adapter makes one minimal (`max_tokens: 1`) inference call and reads the headers,
/// discarding the body. Cost is ~1 token per call → the host polls on demand and caches.
public struct ClaudeUsageAdapter: ProviderUsageAdapter {
    public let provider: UsageProvider = .claude

    /// Reads the OAuth token from the environment (read-only; never logged/persisted).
    private let tokenProvider: @Sendable () -> String?
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        tokenProvider: @escaping @Sendable () -> String? = {
            ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"]
        },
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokenProvider = tokenProvider
        self.session = session
        self.now = now
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw UsageAdapterError.signedOut
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageAdapterError.malformedResponse
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageAdapterError.malformedResponse
        }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw UsageAdapterError.signedOut
        case 429: throw UsageAdapterError.rateLimited
        default: throw UsageAdapterError.httpStatus(http.statusCode)
        }
        return try Self.parseUsage(headers: Self.normalizedHeaders(http), now: now())
    }

    // MARK: - Pure parsing (no I/O — unit-testable against captured headers)

    static func parseUsage(headers: [String: String], now: Date) throws -> UsageSnapshot {
        func number(_ key: String) -> Double? { headers[key].flatMap(Double.init) }

        var windows: [UsageWindow] = []
        // 5-hour window (18000s) and 7-day window (604800s), utilization in 0…1.
        let specs: [(prefix: String, seconds: Int)] = [
            ("anthropic-ratelimit-unified-5h", 18000),
            ("anthropic-ratelimit-unified-7d", 604800),
        ]
        for spec in specs {
            guard let util = number("\(spec.prefix)-utilization") else { continue }
            let reset = number("\(spec.prefix)-reset").map { Date(timeIntervalSince1970: $0) }
            windows.append(
                UsageWindow(kind: .rolling(seconds: spec.seconds), usedPercent: util * 100, resetAt: reset)
            )
        }
        guard !windows.isEmpty else { throw UsageAdapterError.malformedResponse }

        let accountId = headers["anthropic-organization-id"] ?? "default"
        return UsageSnapshot(
            account: ProviderAccount(provider: .claude, accountId: accountId),
            windows: windows,
            freshness: .live(now),
            fetchedAt: now
        )
    }

    static func normalizedHeaders(_ http: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { out[k.lowercased()] = v }
        }
        return out
    }
}
