import Foundation

/// ``BillingAPI`` over the cmux web API with native Stack bearer auth.
///
/// Sends the same headers as the other native `/api` clients
/// (`Authorization: Bearer`, `X-Stack-Refresh-Token`) plus `x-cmux-bundle-id`,
/// which selects the bundle's product ids on the server, and, when known,
/// `x-cmux-storekit-environment` (`Sandbox` or `Production`), which lets the
/// server withhold products whose purchases would grant no plan.
///
/// ```swift
/// let api = HTTPBillingAPI(
///     baseURL: "https://cmux.com",
///     bundleID: "com.cmux.app",
///     credentials: { try await tokens() }
/// )
/// ```
public struct HTTPBillingAPI: BillingAPI {
    /// Reads the current session's tokens; returns nil when signed out.
    public typealias CredentialsProvider = @Sendable () async throws -> BillingAPICredentials?
    /// Reads the app's StoreKit environment (`Sandbox` or `Production`); nil when unknown.
    public typealias EnvironmentProvider = @Sendable () async -> String?

    private let baseURL: String
    private let bundleID: String
    private let credentials: CredentialsProvider
    private let storeKitEnvironment: EnvironmentProvider
    private let session: URLSession
    private let timeout: TimeInterval

    /// Creates the client.
    /// - Parameters:
    ///   - baseURL: The web API origin, with or without a trailing slash.
    ///   - bundleID: The app's bundle id, sent as `x-cmux-bundle-id`.
    ///   - credentials: Reads the Stack session; nil means signed out.
    ///   - storeKitEnvironment: Reads the app's StoreKit environment, sent as
    ///     `x-cmux-storekit-environment`; nil omits the header.
    ///   - session: The URL session. Tests pass one with a stub protocol.
    ///   - timeout: Per-request deadline in seconds.
    public init(
        baseURL: String,
        bundleID: String,
        credentials: @escaping CredentialsProvider,
        storeKitEnvironment: @escaping EnvironmentProvider = { nil },
        session: URLSession,
        timeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.bundleID = bundleID
        self.credentials = credentials
        self.storeKitEnvironment = storeKitEnvironment
        self.session = session
        self.timeout = timeout
    }

    public func accountToken() async throws -> BillingAccount {
        let request = try await makeRequest(path: "/api/billing/apple/account-token", body: Data("{}".utf8))
        return try await send(request, decoding: BillingAccount.self)
    }

    public func submitTransaction(signedTransactionInfo: String) async throws -> BillingTransactionReceipt {
        let body = try JSONEncoder().encode(TransactionBody(signedTransactionInfo: signedTransactionInfo))
        let request = try await makeRequest(path: "/api/billing/apple/transactions", body: body)
        return try await send(request, decoding: BillingTransactionReceipt.self)
    }

    /// Builds a `POST` request; exposed to tests to pin the header contract.
    /// - Parameters:
    ///   - path: The route path, starting with `/`.
    ///   - body: The JSON body.
    /// - Returns: The authenticated request.
    /// - Throws: ``BillingAPIError/notSignedIn`` or ``BillingAPIError/invalidURL``.
    func makeRequest(path: String, body: Data) async throws -> URLRequest {
        guard let url = URL(string: baseURL + path), url.scheme != nil, url.host != nil else {
            throw BillingAPIError.invalidURL
        }
        let pair: BillingAPICredentials?
        do {
            pair = try await credentials()
        } catch {
            throw BillingAPIError.transport
        }
        guard let pair else { throw BillingAPIError.notSignedIn }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(pair.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(pair.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.setValue(bundleID, forHTTPHeaderField: "x-cmux-bundle-id")
        if let environment = await storeKitEnvironment() {
            request.setValue(environment, forHTTPHeaderField: "x-cmux-storekit-environment")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest, decoding: Response.Type) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BillingAPIError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw BillingAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 403, (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error == "account_mismatch" {
                throw BillingAPIError.accountMismatch
            }
            throw BillingAPIError.rejected(statusCode: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BillingAPIError.invalidResponse
        }
    }

    private struct TransactionBody: Encodable {
        let signedTransactionInfo: String
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }
}
