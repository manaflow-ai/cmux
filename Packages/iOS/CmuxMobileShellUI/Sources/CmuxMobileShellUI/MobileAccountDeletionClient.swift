import CmuxAuthRuntime
import Foundation

/// Client that submits account deletion requests from the mobile settings UI.
public struct MobileAccountDeletionClient: Sendable {
    /// Backward-compatible nested name for mobile account deletion request failures.
    public typealias DeletionError = MobileAccountDeletionError

    private let apiBaseURL: String
    private let tokenProvider: any TokenProviding
    private let session: URLSession
    private let requestTimeout: TimeInterval

    /// Creates a client for the account deletion endpoint at the given API base URL.
    public init(
        apiBaseURL: String,
        tokenProvider: any TokenProviding,
        session: sending URLSession = .shared,
        requestTimeout: TimeInterval = 30
    ) {
        self.apiBaseURL = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        self.tokenProvider = tokenProvider
        self.session = session
        self.requestTimeout = requestTimeout
    }

    /// Sends the authenticated account deletion request and validates the HTTP response.
    public func deleteAccount() async throws {
        let accessToken = try await tokenProvider.accessToken()
        guard let refreshToken = await tokenProvider.refreshToken(), !refreshToken.isEmpty else {
            throw DeletionError.missingRefreshToken
        }
        guard let url = URL(string: apiBaseURL + "/api/account/deletion") else {
            throw DeletionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeletionError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw DeletionError.rejected(statusCode: http.statusCode)
        }
    }
}
