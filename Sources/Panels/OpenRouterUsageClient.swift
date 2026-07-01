import Foundation

/// OpenRouter account balance, in OpenRouter credits (USD-denominated).
struct OpenRouterCredits: Equatable, Sendable {
    /// Total credits ever purchased.
    var totalCredits: Double
    /// Total credits consumed to date.
    var totalUsage: Double
    /// Remaining balance.
    var remaining: Double { totalCredits - totalUsage }
}

/// Usage fetched from OpenRouter for the dashboard: per-day/per-model events
/// plus the current account balance.
struct OpenRouterUsage: Equatable, Sendable {
    /// One event per (day, model) row OpenRouter reported.
    var events: [AgentUsageEvent]
    /// Account balance, when the credits endpoint succeeded.
    var credits: OpenRouterCredits?
}

/// Reasons an OpenRouter fetch can fail, surfaced to the dashboard.
enum OpenRouterUsageError: LocalizedError, Equatable {
    /// HTTP 401/403 — the key is wrong or lacks the required scope.
    case unauthorized
    /// Any other non-success HTTP status.
    case httpStatus(Int)
    /// The response body did not decode.
    case decoding

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(
                localized: "agentUsage.openRouter.error.unauthorized",
                defaultValue: "OpenRouter rejected the key. The usage dashboard needs a provisioning (management) key, not a regular inference key."
            )
        case let .httpStatus(code):
            return String(
                format: String(localized: "agentUsage.openRouter.error.http", defaultValue: "OpenRouter request failed (HTTP %d)."),
                code
            )
        case .decoding:
            return String(
                localized: "agentUsage.openRouter.error.decoding",
                defaultValue: "OpenRouter returned an unexpected response."
            )
        }
    }
}

/// Fetches account usage from the OpenRouter HTTP API.
///
/// The `/api/v1/activity` and `/api/v1/credits` endpoints both require a
/// **provisioning / management key** (created under OpenRouter Settings →
/// Provisioning Keys), not a standard inference key. `activity` returns usage
/// grouped by UTC day and model for the last 30 completed days.
struct OpenRouterUsageClient: Sendable {
    /// Base API URL (overridable for tests).
    var baseURL: URL
    /// URL session used for requests.
    var session: URLSession

    /// Creates a client against the live OpenRouter API by default.
    init(
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Fetches activity and credits for `apiKey`. Activity is required; a
    /// credits failure is tolerated (balance is supplementary).
    func fetchUsage(apiKey: String) async throws -> OpenRouterUsage {
        let activity = try await fetchActivity(apiKey: apiKey)
        let credits = try? await fetchCredits(apiKey: apiKey)
        return OpenRouterUsage(events: activity, credits: credits)
    }

    // MARK: - Activity

    private struct ActivityResponse: Decodable {
        let data: [ActivityItem]
    }

    private struct ActivityItem: Decodable {
        let date: String
        let model: String
        let promptTokens: Int
        let completionTokens: Int
        let reasoningTokens: Int
        let requests: Int
        let usage: Double

        enum CodingKeys: String, CodingKey {
            case date, model, requests, usage
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case reasoningTokens = "reasoning_tokens"
        }
    }

    private func fetchActivity(apiKey: String) async throws -> [AgentUsageEvent] {
        let data = try await get(path: "activity", apiKey: apiKey)
        guard let decoded = try? JSONDecoder().decode(ActivityResponse.self, from: data) else {
            throw OpenRouterUsageError.decoding
        }
        return decoded.data.compactMap(Self.event(from:))
    }

    /// Maps one activity row to a usage event. The cost OpenRouter reports
    /// (`usage`, in credits) is authoritative, so it is recorded directly.
    private static func event(from item: ActivityItem) -> AgentUsageEvent? {
        guard let day = dayFormatter.date(from: item.date) else { return nil }
        let tokens = AgentUsageTokens(
            input: max(0, item.promptTokens),
            output: max(0, item.completionTokens) + max(0, item.reasoningTokens),
            cacheRead: 0,
            cacheWrite: 0
        )
        guard !tokens.isEmpty else { return nil }
        return AgentUsageEvent(
            source: .openRouter,
            // OpenRouter dates are UTC days; place the event at noon UTC so the
            // aggregator's day-bucketing lands on the reported date.
            timestamp: day.addingTimeInterval(12 * 60 * 60),
            model: item.model,
            tokens: tokens,
            recordedCostUSD: item.usage
        )
    }

    /// Parses OpenRouter's `YYYY-MM-DD` activity dates (UTC).
    private nonisolated(unsafe) static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Credits

    private struct CreditsResponse: Decodable {
        let data: CreditsData

        struct CreditsData: Decodable {
            let totalCredits: Double
            let totalUsage: Double

            enum CodingKeys: String, CodingKey {
                case totalCredits = "total_credits"
                case totalUsage = "total_usage"
            }
        }
    }

    private func fetchCredits(apiKey: String) async throws -> OpenRouterCredits {
        let data = try await get(path: "credits", apiKey: apiKey)
        guard let decoded = try? JSONDecoder().decode(CreditsResponse.self, from: data) else {
            throw OpenRouterUsageError.decoding
        }
        return OpenRouterCredits(
            totalCredits: decoded.data.totalCredits,
            totalUsage: decoded.data.totalUsage
        )
    }

    // MARK: - Transport

    private func get(path: String, apiKey: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterUsageError.decoding
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw OpenRouterUsageError.unauthorized
        default:
            throw OpenRouterUsageError.httpStatus(http.statusCode)
        }
    }
}

/// Maps an `ActivityResponse`-shaped JSON payload into events for testing the
/// mapping without a live network call.
extension OpenRouterUsageClient {
    /// Decodes an `/api/v1/activity` JSON body into usage events. Exposed for
    /// unit tests; returns an empty array when the body does not decode.
    static func events(fromActivityJSON json: Data) -> [AgentUsageEvent] {
        guard let decoded = try? JSONDecoder().decode(ActivityResponse.self, from: json) else {
            return []
        }
        return decoded.data.compactMap(event(from:))
    }
}
