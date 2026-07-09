import Foundation

public enum AccountDeletionRequestError: Error, Equatable {
    case invalidAPIBaseURL
    case unauthorized
    case stackDeleteIncomplete
    /// The DELETE request reached the transport layer and timed out before a
    /// definitive response. The backend may still complete account deletion, so
    /// callers must treat the local session as no longer trustworthy.
    case timedOut
    /// The DELETE request reached the network/server boundary but did not return
    /// a definitive account-deletion result. The backend may still complete
    /// deletion after this client gives up.
    case completionUnknown
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

    @concurrent
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
        } catch is URLError {
            throw AccountDeletionRequestError.completionUnknown
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
            let errorCode = Self.errorCode(in: data)
            if Self.isRetryablePartialDeletionError(errorCode) {
                throw AccountDeletionRequestError.stackDeleteIncomplete
            }
            if Self.isDefinitiveFailureError(errorCode) {
                throw AccountDeletionRequestError.rejected(statusCode: httpResponse.statusCode)
            }
            if Self.isAmbiguousHTTPStatus(httpResponse.statusCode) {
                throw AccountDeletionRequestError.completionUnknown
            }
            throw AccountDeletionRequestError.rejected(statusCode: httpResponse.statusCode)
        }
    }

    private static func errorCode(in data: Data) -> String? {
        try? JSONDecoder().decode(AccountDeletionErrorResponse.self, from: data).error
    }

    private static func isRetryablePartialDeletionError(_ code: String?) -> Bool {
        code == "account_delete_retryable" ||
            code == "account_stack_delete_failed_after_data_delete"
    }

    private static func isDefinitiveFailureError(_ code: String?) -> Bool {
        code == "account_delete_failed"
    }

    private static func isAmbiguousHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode >= 500
    }
}

extension AuthCoordinator {
    /// Permanently deletes the current Stack account through cmux's backend.
    ///
    /// Callers clear local shell/auth state through their normal sign-out owner
    /// after this succeeds so app-level teardown hooks run in the right order.
    public func deleteAccount() async throws {
        let apiBaseURL = apiBaseURL
        let timeout = timeouts.network
        let tokens = try await runTokenTouchingPhase(.accountDeletion, timeout: timeout) {
            try await self.currentTokens()
        }
        try await AccountDeletionClient(
            apiBaseURL: apiBaseURL,
            requestTimeout: timeout.urlRequestTimeoutInterval
        ).deleteAccount(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken
        )
    }
}

private extension Duration {
    var urlRequestTimeoutInterval: TimeInterval {
        let value = components
        return TimeInterval(value.seconds) + TimeInterval(value.attoseconds) / 1_000_000_000_000_000_000
    }
}
