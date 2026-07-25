public import Foundation

/// Grok usage adapter.
///
/// Grok's proxy has no dedicated usage endpoint, but — like Claude — a real inference
/// call returns quota in `x-ratelimit-*` response headers (remaining/limit tokens and
/// requests; no reset epoch). The proxy gates inference on an `x-grok-client-version`
/// header (426 without it). The bearer key is read read-only from `~/.grok/auth.json`.
/// One minimal call per fetch; the host polls on demand and caches.
public struct GrokUsageAdapter: ProviderUsageAdapter {
    public let provider: UsageProvider = .grok

    private let authFileURL: URL
    private let clientVersion: String
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        authFileURL: URL? = nil,
        clientVersion: String = "0.2.22",
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authFileURL = authFileURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok/auth.json")
        self.clientVersion = clientVersion
        self.session = session
        self.now = now
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let auth = try Self.readAuth(fromFileAt: authFileURL)

        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(auth.key)", forHTTPHeaderField: "Authorization")
        request.setValue(clientVersion, forHTTPHeaderField: "x-grok-client-version")
        request.setValue("grok-cli", forHTTPHeaderField: "x-grok-client-identifier")
        if let userId = auth.userId { request.setValue(userId, forHTTPHeaderField: "x-grok-user-id") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "grok-4.5",
            "input": "hi",
            "max_output_tokens": 1,
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
        return try Self.parseUsage(headers: ClaudeUsageAdapter.normalizedHeaders(http), now: now())
    }

    // MARK: - Pure parsing (no I/O — unit-testable against captured headers)

    static func parseUsage(headers: [String: String], now: Date) throws -> UsageSnapshot {
        func number(_ key: String) -> Double? { headers[key].flatMap(Double.init) }

        var windows: [UsageWindow] = []
        let specs: [(unit: String, remaining: String, limit: String)] = [
            ("tokens", "x-ratelimit-remaining-tokens", "x-ratelimit-limit-tokens"),
            ("requests", "x-ratelimit-remaining-requests", "x-ratelimit-limit-requests"),
        ]
        for spec in specs {
            guard let remaining = number(spec.remaining),
                  let limit = number(spec.limit), limit > 0 else { continue }
            let used = max(0, min(100, (1 - remaining / limit) * 100))
            windows.append(
                UsageWindow(kind: .quota(unit: spec.unit), usedPercent: used, remaining: remaining, limit: limit)
            )
        }
        guard !windows.isEmpty else { throw UsageAdapterError.malformedResponse }

        return UsageSnapshot(
            account: ProviderAccount(provider: .grok, accountId: "default"),
            windows: windows,
            freshness: .live(now),
            fetchedAt: now
        )
    }

    // MARK: - Read-only credential access

    struct GrokAuth: Sendable {
        let key: String
        let userId: String?
    }

    static func readAuth(fromFileAt url: URL) throws -> GrokAuth {
        guard let data = try? Data(contentsOf: url) else {
            throw UsageAdapterError.notInstalled
        }
        // auth.json is keyed by "<issuer>::<id>" → object with .key / .user_id.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageAdapterError.signedOut
        }
        for value in root.values {
            if let entry = value as? [String: Any],
               let key = entry["key"] as? String, !key.isEmpty {
                return GrokAuth(key: key, userId: entry["user_id"] as? String)
            }
        }
        throw UsageAdapterError.signedOut
    }
}
