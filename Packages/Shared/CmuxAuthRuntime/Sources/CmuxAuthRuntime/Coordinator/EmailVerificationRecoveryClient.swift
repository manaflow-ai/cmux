import Foundation

/// Requests Stack contact-channel verification through the cmux backend.
struct EmailVerificationRecoveryClient: Sendable {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct RequestBody: Encodable {
        let email: String
    }

    private let apiBaseURL: String
    private let requestTimeout: TimeInterval
    private let load: Loader

    init(
        apiBaseURL: String,
        requestTimeout: TimeInterval = 60,
        load: @escaping Loader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.apiBaseURL = apiBaseURL
        self.requestTimeout = requestTimeout
        self.load = load
    }

    @concurrent
    func requestVerification(for email: String) async throws {
        let baseURL = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        guard let url = URL(string: baseURL + "/api/auth/email-verification") else {
            throw EmailVerificationRecoveryRequestError.invalidAPIBaseURL
        }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        )

        let response: URLResponse
        do {
            (_, response) = try await load(request)
        } catch {
            throw EmailVerificationRecoveryRequestError.unavailable
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmailVerificationRecoveryRequestError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return
        case 429:
            throw EmailVerificationRecoveryRequestError.rateLimited
        default:
            throw EmailVerificationRecoveryRequestError.unavailable
        }
    }
}
