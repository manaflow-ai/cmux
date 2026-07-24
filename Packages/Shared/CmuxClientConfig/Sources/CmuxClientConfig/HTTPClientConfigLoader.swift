public import Foundation

/// A URLSession-backed loader for the cmux `/api/client-config` route.
public struct HTTPClientConfigLoader: ClientConfigLoading {
    private let apiBaseURL: String
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates an HTTP loader.
    ///
    /// - Parameters:
    ///   - apiBaseURL: The cmux web API origin, with or without a trailing slash.
    ///   - session: The URLSession used for the request.
    ///   - encoder: Encoder for the request body.
    ///   - decoder: Decoder for the response body.
    public init(
        apiBaseURL: String,
        session: sending URLSession = .shared,
        encoder: sending JSONEncoder = JSONEncoder(),
        decoder: sending JSONDecoder = JSONDecoder()
    ) {
        self.apiBaseURL = apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.session = session
        self.encoder = encoder
        self.decoder = decoder
    }

    /// POSTs the request to `/api/client-config` and decodes the typed response.
    public func load(_ request: ClientConfigRequest) async throws -> ClientConfig {
        guard let url = URL(string: apiBaseURL + "/api/client-config") else {
            throw ClientConfigError.invalidBaseURL
        }

        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ClientConfigError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ClientConfigError.httpStatus(http.statusCode)
        }
        return try decoder.decode(ClientConfig.self, from: data)
    }
}
