import Foundation

enum AccountDeletionRequestError: Error, Equatable {
    case invalidAPIBaseURL
    case unauthorized
    case rejected(statusCode: Int)
    case invalidResponse
}

typealias AccountDeletionRequestLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

struct AccountDeletionClient: Sendable {
    private let apiBaseURL: String
    private let load: AccountDeletionRequestLoader

    init(
        apiBaseURL: String,
        load: @escaping AccountDeletionRequestLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.apiBaseURL = apiBaseURL
        self.load = load
    }

    func deleteAccount(accessToken: String, refreshToken: String) async throws {
        guard let baseURL = URL(string: apiBaseURL),
              let url = URL(string: "/api/account", relativeTo: baseURL)?.absoluteURL
        else {
            throw AccountDeletionRequestError.invalidAPIBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")

        let (_, response) = try await load(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AccountDeletionRequestError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return
        case 401:
            throw AccountDeletionRequestError.unauthorized
        default:
            throw AccountDeletionRequestError.rejected(statusCode: httpResponse.statusCode)
        }
    }
}

extension AuthCoordinator {
    /// Permanently deletes the current Stack account through cmux's backend and
    /// then clears the local session using the same local-first path as sign-out.
    public func deleteAccount(teardownTimeout: Duration = .seconds(5)) async throws {
        let tokens = try await currentTokens()
        try await AccountDeletionClient(apiBaseURL: apiBaseURL).deleteAccount(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken
        )
        await signOut(teardownTimeout: teardownTimeout)
    }
}
