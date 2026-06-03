public import Foundation

/// Performs authenticated POST requests against the Next.js mobile API.
///
/// Each request encodes a `Codable` body, attaches a bearer token from the injected
/// ``AuthTokenProviding``, and decodes the JSON response. Non-2xx responses surface as
/// ``MobileRouteClientError/httpError(_:_:)`` with a best-effort parsed error message.
@MainActor
public final class MobileAuthenticatedRouteTransport {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: any AuthTokenProviding
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Creates a transport bound to a base URL, URL session, and token provider.
    ///
    /// - Parameters:
    ///   - baseURL: The mobile API base URL; request paths are appended to it.
    ///   - session: The URL session used to perform requests. Defaults to `.shared`.
    ///   - tokenProvider: The auth seam supplying bearer tokens and authentication state.
    public init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenProvider: any AuthTokenProviding
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    /// Whether a user is currently authenticated.
    public var isAuthenticated: Bool {
        tokenProvider.isAuthenticated
    }

    /// Sends an encodable body to a path and decodes the response.
    ///
    /// - Parameters:
    ///   - path: The API path appended to the base URL (for example `api/mobile/push/register`).
    ///   - body: The request payload encoded as JSON.
    ///   - responseType: The decodable type to decode the response into.
    /// - Returns: The decoded response value.
    /// - Throws: ``MobileRouteClientError`` for invalid or non-2xx responses, or an encoding,
    ///   decoding, networking, or token-acquisition error.
    public func send<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        responseType: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await tokenProvider.accessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MobileRouteClientError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw MobileRouteClientError.httpError(
                httpResponse.statusCode,
                Self.parseErrorMessage(from: data)
            )
        }

        return try decoder.decode(Response.self, from: data)
    }

    private static func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = payload["error"] as? String, !error.isEmpty {
                return error
            }
            if let message = payload["message"] as? String, !message.isEmpty {
                return message
            }
        }
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return nil
    }
}
