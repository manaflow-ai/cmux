import CmuxAuthRuntime
import Foundation

enum CoderouterClientError: Error, CustomStringConvertible {
    case notSignedIn
    case backendUnreachable(url: String, detail: String)
    case httpStatus(Int, String)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .notSignedIn:
            return """
                You are not signed in to cmux.

                What to do:
                  cmux auth login
                  cmux auth status
                """
        case .backendUnreachable(let url, let detail):
            return """
                Cannot reach the cmux AI Gateway service at \(url).

                What to do:
                  Start the cmux web server, then retry.
                  If you are using a local development build, check its AI Gateway service URL before launching cmux.

                Details:
                  \(detail)
                """
        case .httpStatus(let code, let body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return """
                AI Gateway request failed (HTTP \(code)).

                Response body:
                  \(trimmedBody.isEmpty ? "<empty>" : trimmedBody)
                """
        case .malformedResponse(let message):
            return """
                The cmux AI Gateway backend returned a response this client could not read.

                Details:
                  \(message)
                """
        }
    }
}

struct CoderouterKeySummary: Equatable, Sendable {
    let id: String
    let name: String
    let policy: [String: AnySendable]
    let createdAt: String
    let revokedAt: String?
    let lastUsedAt: String?
}

struct CoderouterUsageTotal: Equatable, Sendable {
    let day: String
    let model: String
    let credentialClass: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let costMicros: Int
    let requests: Int
}

struct CoderouterUsageSummary: Equatable, Sendable {
    let days: Int
    let balanceMicros: Int
    let totals: [CoderouterUsageTotal]
}

/// Sendable wrapper for JSON policy values surfaced by the control plane.
enum AnySendable: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([AnySendable])
    case object([String: AnySendable])
    case null
}

/// Talks to the cmux coderouter control plane at `/api/coderouter/*`.
///
/// Stack Auth tokens come from the injected `AuthCoordinator`; the HTTP base
/// URL comes from `AuthEnvironment.coderouterBaseURL`.
actor CoderouterClient {
    /// Set once by `bootstrap(auth:)` during app startup.
    @MainActor private(set) static var shared: CoderouterClient!

    /// Build the shared client with its injected auth dependency.
    @MainActor
    static func bootstrap(auth: AuthCoordinator, session: URLSession = .shared) {
        shared = CoderouterClient(session: session, auth: auth)
    }

    private let session: URLSession
    private let auth: AuthCoordinator

    init(session: URLSession = .shared, auth: AuthCoordinator) {
        self.session = session
        self.auth = auth
    }

    func createKey(name: String) async throws -> (key: String, id: String) {
        let (data, http) = try await request(
            "POST",
            path: "/api/coderouter/keys",
            jsonBody: ["name": name]
        )
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let key = obj["key"] as? String, key.hasPrefix("crk_"),
              let id = obj["id"] as? String, !id.isEmpty else {
            throw CoderouterClientError.malformedResponse("AI Gateway key response was missing required fields.")
        }
        return (key, id)
    }

    func listKeys() async throws -> [CoderouterKeySummary] {
        let (data, http) = try await request("GET", path: "/api/coderouter/keys")
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let items = obj["keys"] as? [[String: Any]] else {
            throw CoderouterClientError.malformedResponse("missing `keys` array")
        }
        return try items.enumerated().map { index, item in
            try decodeKeySummary(item, index: index)
        }
    }

    func revokeKey(id: String) async throws {
        let (data, http) = try await request(
            "DELETE",
            path: "/api/coderouter/keys",
            queryItems: [URLQueryItem(name: "id", value: id)]
        )
        try ensureOK(http, data: data)
    }

    func usageSummary(days: Int) async throws -> CoderouterUsageSummary {
        let clampedDays = min(max(days, 1), 90)
        let (data, http) = try await request(
            "GET",
            path: "/api/coderouter/usage",
            queryItems: [URLQueryItem(name: "days", value: String(clampedDays))]
        )
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        let responseDays = (obj["days"] as? Int) ?? Int((obj["days"] as? Double) ?? Double(clampedDays))
        let balanceMicros = (obj["balanceMicros"] as? Int)
            ?? Int((obj["balanceMicros"] as? Double) ?? 0)
        guard let rawTotals = obj["totals"] as? [[String: Any]] else {
            throw CoderouterClientError.malformedResponse("missing `totals` array")
        }
        let totals = try rawTotals.enumerated().map { index, item in
            try decodeUsageTotal(item, index: index)
        }
        return CoderouterUsageSummary(days: responseDays, balanceMicros: balanceMicros, totals: totals)
    }

    private func request(
        _ method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        jsonBody: [String: Any]? = nil,
        extraHeaders: [String: String] = [:],
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch {
            throw CoderouterClientError.notSignedIn
        }
        let teamID = await auth.resolvedTeamID

        guard var url = URLComponents(url: AuthEnvironment.coderouterBaseURL, resolvingAgainstBaseURL: false) else {
            throw CoderouterClientError.malformedResponse("bad coderouterBaseURL")
        }
        url.path = (url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path) + path
        if !queryItems.isEmpty {
            url.queryItems = queryItems
        }
        guard let resolved = url.url else {
            throw CoderouterClientError.malformedResponse("could not build URL for \(path)")
        }

        var req = URLRequest(url: resolved)
        req.httpMethod = method
        if let timeoutSeconds {
            req.timeoutInterval = timeoutSeconds
        }
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let teamID, !teamID.isEmpty {
            req.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }
        for (key, value) in extraHeaders {
            req.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                let base = "\(AuthEnvironment.coderouterBaseURL.scheme ?? "http")://\(AuthEnvironment.coderouterBaseURL.host ?? "?"):\(AuthEnvironment.coderouterBaseURL.port ?? -1)"
                throw CoderouterClientError.backendUnreachable(url: base, detail: error.localizedDescription)
            default:
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw CoderouterClientError.malformedResponse("non-HTTP response")
        }
        return (data, http)
    }

    private func ensureOK(_ http: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw CoderouterClientError.httpStatus(http.statusCode, body)
        }
    }

    private func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let obj = parsed as? [String: Any] else {
            throw CoderouterClientError.malformedResponse("expected JSON object, got \(type(of: parsed))")
        }
        return obj
    }

    private func decodeKeySummary(_ item: [String: Any], index: Int) throws -> CoderouterKeySummary {
        guard let id = item["id"] as? String, !id.isEmpty,
              let name = item["name"] as? String, !name.isEmpty,
              let createdAt = item["createdAt"] as? String, !createdAt.isEmpty else {
            throw CoderouterClientError.malformedResponse("AI Gateway key response was missing required fields for item \(index).")
        }
        let rawPolicy = item["policy"] as? [String: Any] ?? [:]
        return CoderouterKeySummary(
            id: id,
            name: name,
            policy: rawPolicy.reduce(into: [:]) { result, pair in
                result[pair.key] = AnySendable(jsonValue: pair.value)
            },
            createdAt: createdAt,
            revokedAt: nullableString(item["revokedAt"]),
            lastUsedAt: nullableString(item["lastUsedAt"])
        )
    }

    private func decodeUsageTotal(_ item: [String: Any], index: Int) throws -> CoderouterUsageTotal {
        guard let day = item["day"] as? String, !day.isEmpty,
              let model = item["model"] as? String, !model.isEmpty,
              let credentialClass = item["credentialClass"] as? String, !credentialClass.isEmpty else {
            throw CoderouterClientError.malformedResponse("AI Gateway usage response was missing required fields for item \(index).")
        }
        return CoderouterUsageTotal(
            day: day,
            model: model,
            credentialClass: credentialClass,
            inputTokens: intValue(item["inputTokens"]),
            outputTokens: intValue(item["outputTokens"]),
            cacheReadTokens: intValue(item["cacheReadTokens"]),
            cacheWriteTokens: intValue(item["cacheWriteTokens"]),
            costMicros: intValue(item["costMicros"]),
            requests: intValue(item["requests"])
        )
    }

    private func nullableString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String
    }

    private func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let int64 = value as? Int64 { return Int(int64) }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }
}

private extension AnySendable {
    init(jsonValue: Any) {
        if jsonValue is NSNull {
            self = .null
        } else if let string = jsonValue as? String {
            self = .string(string)
        } else if let number = jsonValue as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        } else if let array = jsonValue as? [Any] {
            self = .array(array.map(AnySendable.init(jsonValue:)))
        } else if let object = jsonValue as? [String: Any] {
            self = .object(object.reduce(into: [:]) { result, pair in
                result[pair.key] = AnySendable(jsonValue: pair.value)
            })
        } else {
            self = .string(String(describing: jsonValue))
        }
    }
}
