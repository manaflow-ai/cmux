import CmuxAuthRuntime
import Foundation

public struct MobileAccountDeletionClient: Sendable {
    public enum DeletionError: Error, Equatable, Sendable {
        case missingRefreshToken
        case invalidURL
        case invalidResponse
        case rejected(statusCode: Int)
    }

    private let apiBaseURL: String
    private let tokenProvider: any TokenProviding
    private let session: URLSession

    public init(
        apiBaseURL: String,
        tokenProvider: any TokenProviding,
        session: sending URLSession = .shared
    ) {
        self.apiBaseURL = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        self.tokenProvider = tokenProvider
        self.session = session
    }

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
