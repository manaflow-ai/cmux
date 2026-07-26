public import Foundation

/// Codex / ChatGPT usage adapter.
///
/// Data path (proven 2026-07-23): `GET https://chatgpt.com/backend-api/codex/usage`
/// with `Authorization: Bearer <access_token>` and `chatgpt-account-id: <account_id>`,
/// both read read-only from `~/.codex/auth.json`. The endpoint anti-abuse-throttles
/// repeated hits (observed 403), so the host fetches on demand and caches — this
/// adapter performs exactly one request per call.
public struct CodexUsageAdapter: ProviderUsageAdapter {
    public let provider: UsageProvider = .codex

    private let authFileURL: URL
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        authFileURL: URL? = nil,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authFileURL = authFileURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/auth.json")
        self.session = session
        self.now = now
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let auth = try Self.readAuth(fromFileAt: authFileURL)

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/usage")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.accountId, forHTTPHeaderField: "chatgpt-account-id")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageAdapterError.malformedResponse
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageAdapterError.malformedResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw UsageAdapterError.signedOut
        case 403, 429:
            throw UsageAdapterError.rateLimited
        default:
            throw UsageAdapterError.httpStatus(http.statusCode)
        }
        guard data.count <= UsageHTTP.maxResponseBytes else {
            throw UsageAdapterError.malformedResponse
        }

        return try Self.parseUsage(data, fallbackAccountId: auth.accountId, now: now())
    }

    // MARK: - Pure parsing (no I/O — unit-testable against the real wire schema)

    /// Wire schema for the Codex usage endpoint. Only the fields the HUD needs are
    /// modeled; unknown fields are ignored, missing fields decode to `nil`, and a
    /// shape that doesn't decode throws `malformedResponse` (fail-closed).
    private struct Wire: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Int?
            let reset_after_seconds: Int?
            let reset_at: Double?
        }
        struct RateLimit: Decodable {
            let primary_window: Window?
            let secondary_window: Window?
        }
        struct Credits: Decodable {
            let has_credits: Bool?
            let unlimited: Bool?
            let balance: Double?
        }
        let account_id: String?
        let plan_type: String?
        let rate_limit: RateLimit?
        let credits: Credits?
    }

    static func parseUsage(
        _ data: Data,
        fallbackAccountId: String,
        now: Date
    ) throws -> UsageSnapshot {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw UsageAdapterError.malformedResponse
        }

        var windows: [UsageWindow] = []
        for window in [wire.rate_limit?.primary_window, wire.rate_limit?.secondary_window] {
            guard let window else { continue }
            // A window is only meaningful if it carries a length.
            guard let seconds = window.limit_window_seconds else { continue }
            let resetAt: Date? = window.reset_at.map { Date(timeIntervalSince1970: $0) }
                ?? window.reset_after_seconds.map { now.addingTimeInterval(TimeInterval($0)) }
            windows.append(
                UsageWindow(
                    kind: .rolling(seconds: seconds),
                    usedPercent: window.used_percent,
                    resetAt: resetAt
                )
            )
        }

        if let credits = wire.credits, credits.has_credits == true, credits.unlimited != true,
           let balance = credits.balance {
            windows.append(UsageWindow(kind: .credits, creditsRemaining: balance))
        }

        // Degrade a response that carried no usage structure at all rather than
        // reporting it as `.live` with an empty gauge (matches Claude/Grok fail-closed
        // on empty). A recognized-but-window-less response (e.g. an unlimited plan) is
        // still a valid live state, so only truly structureless payloads are rejected.
        if windows.isEmpty, wire.rate_limit == nil, wire.credits == nil {
            throw UsageAdapterError.malformedResponse
        }

        let account = ProviderAccount(
            provider: .codex,
            accountId: wire.account_id ?? fallbackAccountId
        )
        return UsageSnapshot(
            account: account,
            planLabel: wire.plan_type,
            windows: windows,
            freshness: .live(now),
            fetchedAt: now
        )
    }

    // MARK: - Read-only credential access (never written, never logged)

    struct CodexAuth: Sendable {
        let accessToken: String
        let accountId: String
    }

    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let access_token: String?
            let account_id: String?
        }
        let tokens: Tokens?
    }

    static func readAuth(fromFileAt url: URL) throws -> CodexAuth {
        guard let data = readCappedCredentialData(at: url) else {
            throw UsageAdapterError.notInstalled
        }
        guard let file = try? JSONDecoder().decode(AuthFile.self, from: data),
              let token = file.tokens?.access_token, !token.isEmpty,
              let accountId = file.tokens?.account_id, !accountId.isEmpty else {
            throw UsageAdapterError.signedOut
        }
        return CodexAuth(accessToken: token, accountId: accountId)
    }
}
