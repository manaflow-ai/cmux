public import Foundation
import os

/// The production ``SubrouterClienting``: a thin `URLSession` client for the
/// daemon's loopback HTTP API.
///
/// Uses an ephemeral session (no cookies, no cache) with short per-request
/// timeouts so an unreachable daemon fails fast instead of stalling callers.
public struct SubrouterHTTPClient: SubrouterClienting {
    private nonisolated static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "SubrouterHTTPClient"
    )

    /// The per-request timeout for reads; connection-refused fails sooner.
    /// Generous because `/usage-status` fans out to provider APIs on the
    /// daemon side — a cold refresh of a large remote pool can exceed 30s,
    /// and a too-tight timeout
    /// reads as "refresh failing" with an empty panel. A genuinely dead
    /// daemon still fails fast at the connection layer, so the long read
    /// timeout only applies while the server is actually working.
    public static let defaultRequestTimeout: TimeInterval = 60
    /// Upper bound for one JSON response before decoding. The hosted/local
    /// daemon caps session rows too, but this protects clients talking to an
    /// older or misconfigured server that ignores that contract.
    public static let maximumResponseBytes = 8 * 1_024 * 1_024

    private let session: URLSession
    // URLSession does not retain its delegate strongly; keep the stateless
    // redirect policy alive for the lifetime of the client.
    private let redirectDelegate: SubrouterHTTPRedirectRejectingDelegate
    private let decoder: JSONDecoder

    /// Creates the production client.
    /// - Parameter requestTimeout: Per-request timeout in seconds.
    public init(requestTimeout: TimeInterval = SubrouterHTTPClient.defaultRequestTimeout) {
        self.init(
            requestTimeout: requestTimeout,
            configuration: .ephemeral
        )
    }

    /// Test seam for supplying a URLProtocol-backed session configuration.
    init(requestTimeout: TimeInterval, configuration: URLSessionConfiguration) {
        let sessionConfiguration = configuration
        sessionConfiguration.timeoutIntervalForRequest = requestTimeout
        sessionConfiguration.timeoutIntervalForResource = requestTimeout * 2
        sessionConfiguration.waitsForConnectivity = false
        let redirectDelegate = SubrouterHTTPRedirectRejectingDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
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
        var request = Self.request(endpoint: endpoint, path: "/_subrouter/reload-accounts")
        request.httpMethod = "POST"
        return try await perform(request)
    }

    // MARK: - Transport

    /// Builds a request for a daemon path, attaching the endpoint's admin
    /// token (required by secured non-loopback servers) when present.
    private static func request(endpoint: SubrouterEndpoint, path: String) -> URLRequest {
        var request = URLRequest(url: endpoint.url(forPath: path))
        if let token = endpoint.adminToken,
           !token.isEmpty,
           endpoint.isLoopback || endpoint.baseURL.scheme?.lowercased() == "https" {
            request.setValue(token, forHTTPHeaderField: "X-Subrouter-Admin-Token")
        }
        return request
    }

    private func get<Payload: Decodable>(
        endpoint: SubrouterEndpoint,
        path: String
    ) async throws -> Payload {
        try await perform(Self.request(endpoint: endpoint, path: path))
    }

    private func perform<Payload: Decodable>(_ request: URLRequest) async throws -> Payload {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            Self.logger.error(
                "Subrouter request failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw SubrouterClientError.unreachable(description: "transport failure")
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let contentLength = http.value(forHTTPHeaderField: "Content-Length") ?? "unknown"
            Self.logger.error(
                "Subrouter HTTP status \(http.statusCode): content_length=\(contentLength, privacy: .public)"
            )
            // The raw body never crosses this boundary: `shortDescription`
            // feeds UI and CLI surfaces, so only the status code is safe.
            throw SubrouterClientError.httpStatus(code: http.statusCode, description: "")
        }
        if let contentLength = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"),
           let declaredLength = Int(contentLength),
           declaredLength > Self.maximumResponseBytes {
            Self.logger.error(
                "Subrouter response exceeds byte budget: \(declaredLength, privacy: .public)"
            )
            throw SubrouterClientError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init)
                ?? 64 * 1_024,
            Self.maximumResponseBytes
        ))
        do {
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else {
                    Self.logger.error("Subrouter response exceeded byte budget while streaming")
                    throw SubrouterClientError.responseTooLarge
                }
                data.append(byte)
            }
        } catch let error as SubrouterClientError {
            throw error
        } catch {
            Self.logger.error(
                "Subrouter response stream failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw SubrouterClientError.unreachable(description: "transport failure")
        }
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch let error as DecodingError {
            Self.logger.error(
                "Subrouter response decode failed: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            throw SubrouterClientError.decoding(description: Self.decodingSummary(error))
        } catch {
            Self.logger.error(
                "Subrouter response decode failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
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

/// Rejects every redirect for requests that may carry a Subrouter admin token.
/// The daemon API uses a configured absolute endpoint; following a redirect
/// would let an intermediary forward that credential to another host or
/// protocol before the caller can inspect the destination.
private final class SubrouterHTTPRedirectRejectingDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
