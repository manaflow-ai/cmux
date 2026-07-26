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

    /// Resolves the OAuth token (read-only; never logged/persisted). Prefers the
    /// environment, then on-disk credential files — see ``resolveToken(environment:homeDirectory:readFile:)``.
    private let tokenProvider: @Sendable () -> String?
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        tokenProvider: @escaping @Sendable () -> String? = { ClaudeUsageAdapter.resolveToken() },
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokenProvider = tokenProvider
        self.session = session
        self.now = now
    }

    // MARK: - Token resolution (read-only, fail-closed)

    static let maxCredentialFileBytes = 1_000_000

    /// Resolve the Claude OAuth token, preferring `CLAUDE_CODE_OAUTH_TOKEN` in the
    /// environment and falling back to on-disk credential files. cmux launched from
    /// Finder/Dock/login does **not** inherit the shell environment, so the file fallback
    /// is what makes usage resolve in normal use. All file access is read-only, size-capped
    /// (``maxCredentialFileBytes``), and fails closed — any missing/oversized/malformed
    /// input yields `nil` (file contents are treated as hostile input, never trusted).
    public static func resolveToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        readFile: @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) -> String? {
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            return token
        }
        // 1. Standard Claude Code OAuth store: { "claudeAiOauth": { "accessToken": "…" } }.
        if let token = tokenFromCredentialsJSON(
            readFile(homeDirectory.appendingPathComponent(".claude/.credentials.json"))
        ) {
            return token
        }
        // 2. Shell env-file convention: a line `export CLAUDE_CODE_OAUTH_TOKEN=<value>`.
        if let token = tokenFromEnvFile(
            readFile(homeDirectory.appendingPathComponent(".claude/.env"))
        ) {
            return token
        }
        return nil
    }

    /// Parse the OAuth access token out of a Claude Code `.credentials.json`. Strict Codable,
    /// size-capped, returns `nil` on any drift.
    static func tokenFromCredentialsJSON(_ data: Data?) -> String? {
        guard let data, data.count <= maxCredentialFileBytes else { return nil }
        struct Creds: Decodable {
            struct OAuth: Decodable { let accessToken: String? }
            let claudeAiOauth: OAuth?
        }
        guard let creds = try? JSONDecoder().decode(Creds.self, from: data),
              let token = creds.claudeAiOauth?.accessToken, !token.isEmpty else {
            return nil
        }
        return token
    }

    /// Parse `CLAUDE_CODE_OAUTH_TOKEN` out of a shell env file (`export KEY=value` or
    /// `KEY=value`, optional surrounding quotes). Size-capped, returns `nil` if absent/empty.
    static func tokenFromEnvFile(_ data: Data?) -> String? {
        guard let data, data.count <= maxCredentialFileBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard line.hasPrefix("CLAUDE_CODE_OAUTH_TOKEN=") else { continue }
            var value = String(line.dropFirst("CLAUDE_CODE_OAUTH_TOKEN=".count))
            if let quote = value.first, quote == "\"" || quote == "'",
               value.count >= 2, value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            value = value.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
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
