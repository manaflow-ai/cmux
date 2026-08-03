public import Foundation

/// Fetches short-lived OpenAI Realtime credentials from the authenticated cmux API.
public actor HTTPRealtimeVoiceClientSecretProvider: RealtimeVoiceClientSecretProviding {
    private static let expectedModel = "gpt-realtime-2.1"

    private let endpoint: URL?
    private let tokenSource: RealtimeVoiceTokenSource
    private let session: any RealtimeVoiceHTTPSession
    private let now: @Sendable () -> Date

    /// Creates a backend credential provider.
    /// - Parameters:
    ///   - apiBaseURL: Authenticated cmux web API origin.
    ///   - tokenSource: Live Stack Auth token source.
    ///   - session: Injected HTTP transport.
    ///   - now: Injected clock used to reject expired credentials.
    public init(
        apiBaseURL: String,
        tokenSource: RealtimeVoiceTokenSource,
        session: any RealtimeVoiceHTTPSession = URLSession.shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let trimmed = apiBaseURL.hasSuffix("/")
            ? String(apiBaseURL.dropLast())
            : apiBaseURL
        self.endpoint = URL(string: trimmed + "/api/realtime/client-secret")
        self.tokenSource = tokenSource
        self.session = session
        self.now = now
    }

    /// Fetch a fresh credential without exposing the OpenAI project key to iOS.
    public func fetchClientSecret() async throws -> RealtimeVoiceClientSecret {
        guard let endpoint else {
            throw RealtimeVoiceClientSecretError.invalidConfiguration
        }
        guard let accessToken = await tokenSource.accessToken(),
              let refreshToken = await tokenSource.refreshToken(),
              !accessToken.isEmpty,
              !refreshToken.isEmpty else {
            throw RealtimeVoiceClientSecretError.notAuthenticated
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RealtimeVoiceClientSecretError.serviceUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw RealtimeVoiceClientSecretError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw RealtimeVoiceClientSecretError.notAuthenticated
        case 429:
            throw RealtimeVoiceClientSecretError.rateLimited
        default:
            throw RealtimeVoiceClientSecretError.serviceUnavailable
        }
        guard data.count <= 16 * 1_024,
              let secret = try? JSONDecoder().decode(RealtimeVoiceClientSecret.self, from: data),
              secret.value.hasPrefix("ek_"),
              secret.value.count <= 4_096,
              secret.model == Self.expectedModel,
              TimeInterval(secret.expiresAt) > now().timeIntervalSince1970 else {
            throw RealtimeVoiceClientSecretError.invalidResponse
        }
        return secret
    }
}
