import Foundation

typealias AccountDeletionRequestLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// The deletion route answered that it is not served on this deployment
/// (an origin whose backend has not shipped it yet). Nothing was deleted.
struct AccountDeletionRouteUnavailable: Error, Equatable {
    let statusCode: Int
}

struct AccountDeletionClient: Sendable {
    /// cmux.com's account route: deletes the Stack account (which ends every
    /// session), billing and the cmux data it owns.
    static let accountPath = "/api/account"
    /// The NEXT Cloud route (cmux-platform `DELETE /v1/me`): erases the data
    /// NEXT Cloud holds for the account, then does what `accountPath` does.
    static let cloudPath = "/v1/me"

    private let apiBaseURL: String
    private let path: String
    private let unavailableStatusCodes: Set<Int>
    private let requestTimeout: TimeInterval
    private let load: AccountDeletionRequestLoader

    /// `unavailableStatusCodes`: statuses that mean the route is not on this
    /// deployment; they throw `AccountDeletionRouteUnavailable` instead of a
    /// rejection, so a caller can use another route.
    init(
        apiBaseURL: String,
        path: String = AccountDeletionClient.accountPath,
        unavailableStatusCodes: Set<Int> = [],
        requestTimeout: TimeInterval = 60,
        load: @escaping AccountDeletionRequestLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.apiBaseURL = apiBaseURL
        self.path = path
        self.unavailableStatusCodes = unavailableStatusCodes
        self.requestTimeout = requestTimeout
        self.load = load
    }

    @concurrent
    func deleteAccount(accessToken: String, refreshToken: String) async throws -> AccountDeletionResult {
        let trimmedBaseURL = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        guard let url = URL(string: trimmedBaseURL + path) else {
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
        } catch let error as URLError {
            guard !isDefiniteLocalAccountDeletionTransportFailure(error.code) else {
                throw AccountDeletionRequestError.localTransportFailure
            }
            throw AccountDeletionRequestError.completionUnknown
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AccountDeletionRequestError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return try accountDeletionResult(in: data)
        case 401:
            throw AccountDeletionRequestError.unauthorized
        case let status where unavailableStatusCodes.contains(status):
            throw AccountDeletionRouteUnavailable(statusCode: status)
        default:
            let errorCode = accountDeletionErrorCode(in: data)
            if isRetryablePartialAccountDeletionError(errorCode) {
                throw AccountDeletionRequestError.stackDeleteIncomplete
            }
            if isDefinitiveAccountDeletionFailureError(errorCode) {
                throw AccountDeletionRequestError.rejected(statusCode: httpResponse.statusCode)
            }
            if isAmbiguousAccountDeletionHTTPStatus(httpResponse.statusCode) {
                throw AccountDeletionRequestError.completionUnknown
            }
            throw AccountDeletionRequestError.rejected(statusCode: httpResponse.statusCode)
        }
    }
}

private func accountDeletionResult(in data: Data) throws -> AccountDeletionResult {
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return .completed
    }
    if object["deletionPending"] as? Bool == true {
        throw AccountDeletionRequestError.completionUnknown
    }
    guard object["cleanupIncomplete"] as? Bool == true else {
        return .completed
    }
    return .completedWithIncompleteServerCleanup
}

private func accountDeletionErrorCode(in data: Data) -> String? {
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let error = object["error"] as? String
    else {
        return nil
    }
    return error
}

private func isRetryablePartialAccountDeletionError(_ code: String?) -> Bool {
    code == "account_delete_retryable" ||
        code == "account_stack_delete_failed_after_data_delete"
}

private func isDefinitiveAccountDeletionFailureError(_ code: String?) -> Bool {
    code == "account_delete_failed"
}

private func isAmbiguousAccountDeletionHTTPStatus(_ statusCode: Int) -> Bool {
    statusCode == 408 || statusCode >= 500
}

private func isDefiniteLocalAccountDeletionTransportFailure(_ code: URLError.Code) -> Bool {
    switch code {
    case .appTransportSecurityRequiresSecureConnection,
         .badURL,
         .callIsActive,
         .cannotConnectToHost,
         .cannotFindHost,
         .cannotLoadFromNetwork,
         .clientCertificateRejected,
         .clientCertificateRequired,
         .dataNotAllowed,
         .dnsLookupFailed,
         .internationalRoamingOff,
         .notConnectedToInternet,
         .secureConnectionFailed,
         .serverCertificateHasBadDate,
         .serverCertificateHasUnknownRoot,
         .serverCertificateNotYetValid,
         .serverCertificateUntrusted,
         .unsupportedURL:
        return true
    default:
        return false
    }
}
