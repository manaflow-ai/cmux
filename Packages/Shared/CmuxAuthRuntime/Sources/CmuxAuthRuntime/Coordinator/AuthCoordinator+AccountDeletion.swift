import Foundation

public enum AccountDeletionRequestError: Error, Equatable {
    case invalidAPIBaseURL
    case unauthorized
    case stackDeleteIncomplete
    case timedOut
    case rejected(statusCode: Int)
    case invalidResponse
}

typealias AccountDeletionRequestLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

nonisolated private struct AccountDeletionErrorResponse: Decodable {
    let error: String
}

struct AccountDeletionClient: Sendable {
    private let apiBaseURL: String
    private let requestTimeout: TimeInterval
    private let load: AccountDeletionRequestLoader

    init(
        apiBaseURL: String,
        requestTimeout: TimeInterval = 60,
        load: @escaping AccountDeletionRequestLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.apiBaseURL = apiBaseURL
        self.requestTimeout = requestTimeout
        self.load = load
    }

    func deleteAccount(accessToken: String, refreshToken: String) async throws {
        let trimmedBaseURL = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        guard let url = URL(string: trimmedBaseURL + "/api/account") else {
            throw AccountDeletionRequestError.invalidAPIBaseURL
        }

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await load(request)
        } catch let error as URLError where error.code == .timedOut {
            throw AccountDeletionRequestError.timedOut
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AccountDeletionRequestError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return
        case 401:
            throw AccountDeletionRequestError.unauthorized
        default:
            if Self.errorCode(in: data) == "account_stack_delete_failed_after_data_delete" {
                throw AccountDeletionRequestError.stackDeleteIncomplete
            }
            throw AccountDeletionRequestError.rejected(statusCode: httpResponse.statusCode)
        }
    }

    private static func errorCode(in data: Data) -> String? {
        try? JSONDecoder().decode(AccountDeletionErrorResponse.self, from: data).error
    }
}

extension AuthCoordinator {
    /// Permanently deletes the current Stack account through cmux's backend.
    ///
    /// Callers clear local shell/auth state through their normal sign-out owner
    /// after this succeeds so app-level teardown hooks run in the right order.
    public func deleteAccount() async throws {
        let tokens = try await currentTokens()
        let apiBaseURL = apiBaseURL
        let timeout = timeouts.network
        try await runPhase(.accountDeletion, timeout: timeout) {
            try await AccountDeletionClient(apiBaseURL: apiBaseURL).deleteAccount(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken
            )
        }
    }
}
