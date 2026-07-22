public import Foundation

/// The production ``SubrouterClienting``: a thin `URLSession` client for the
/// daemon's loopback HTTP API.
///
/// Uses an ephemeral session (no cookies, no cache) with short per-request
/// timeouts so an unreachable daemon fails fast instead of stalling callers.
public struct SubrouterHTTPClient: SubrouterClienting {
    /// The per-request timeout for reads; connection-refused fails sooner.
    public static let defaultRequestTimeout: TimeInterval = 5

    private let session: URLSession
    private let decoder: JSONDecoder

    /// Creates the production client.
    /// - Parameter requestTimeout: Per-request timeout in seconds.
    public init(requestTimeout: TimeInterval = SubrouterHTTPClient.defaultRequestTimeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
        self.decoder = Self.makeDecoder()
    }

    public func health(endpoint: SubrouterEndpoint) async throws -> Bool {
        struct HealthPayload: Codable {
            var ok: Bool?
        }
        let payload: HealthPayload = try await get(endpoint: endpoint, path: "/_subrouter/health")
        return payload.ok ?? false
    }

    public func accounts(endpoint: SubrouterEndpoint) async throws -> [SubrouterAccount] {
        try await get(endpoint: endpoint, path: "/_subrouter/accounts")
    }

    public func usageStatuses(endpoint: SubrouterEndpoint) async throws -> [SubrouterAccountUsageStatus] {
        try await get(endpoint: endpoint, path: "/_subrouter/usage-status")
    }

    public func sessions(endpoint: SubrouterEndpoint) async throws -> [SubrouterSessionAssignment] {
        try await get(endpoint: endpoint, path: "/_subrouter/sessions")
    }

    public func reloadAccounts(endpoint: SubrouterEndpoint) async throws -> SubrouterReloadResult {
        var request = URLRequest(url: endpoint.url(forPath: "/_subrouter/reload-accounts"))
        request.httpMethod = "POST"
        return try await perform(request)
    }

    // MARK: - Transport

    private func get<Payload: Decodable>(
        endpoint: SubrouterEndpoint,
        path: String
    ) async throws -> Payload {
        try await perform(URLRequest(url: endpoint.url(forPath: path)))
    }

    private func perform<Payload: Decodable>(_ request: URLRequest) async throws -> Payload {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SubrouterClientError.unreachable(description: error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // The raw body never crosses this boundary: `shortDescription`
            // feeds UI and CLI surfaces, so only the status code is safe.
            throw SubrouterClientError.httpStatus(code: http.statusCode, description: "")
        }
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch let error as DecodingError {
            throw SubrouterClientError.decoding(description: Self.decodingSummary(error))
        } catch {
            throw SubrouterClientError.decoding(description: "unexpected daemon response")
        }
    }

    /// A payload-free summary of a decode failure, safe for user-facing
    /// error text (never includes response contents or coding-path dumps).
    private static func decodingSummary(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound:
            return "unexpected daemon response (missing field)"
        case .valueNotFound:
            return "unexpected daemon response (missing value)"
        case .typeMismatch:
            return "unexpected daemon response (type mismatch)"
        case .dataCorrupted:
            return "unexpected daemon response (corrupt payload)"
        @unknown default:
            return "unexpected daemon response"
        }
    }

    /// Builds the payload decoder. Dates arrive as Go RFC3339Nano strings
    /// (fractional seconds are optional), so both ISO 8601 variants are
    /// tried. No key-conversion strategy: window/credit keys are PascalCase
    /// and carried by explicit `CodingKeys`.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = SubrouterHTTPClient.parseTimestamp(raw) {
                return date
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unrecognized RFC 3339 timestamp: \(raw)"
                )
            )
        }
        return decoder
    }

    // ISO8601DateFormatter is Apple-documented thread-safe; shared parsers
    // avoid per-decode allocation.
    private nonisolated(unsafe) static let fractionalTimestampParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plainTimestampParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses one Go RFC3339Nano timestamp (fractional seconds optional).
    static func parseTimestamp(_ raw: String) -> Date? {
        fractionalTimestampParser.date(from: raw) ?? plainTimestampParser.date(from: raw)
    }
}
