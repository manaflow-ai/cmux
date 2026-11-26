import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ``BillingAPI`` over classic web or cmux-platform with native Stack bearer auth.
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

    /// Selects the server wire contract. Existing callers keep classic until platform rollout is complete.
    public enum Backend: Sendable {
        case classic
        case platform
    }

    private let backend: Backend
    private let baseURL: String
    private let bundleID: String
    private let credentials: CredentialsProvider
    private let storeKitEnvironment: EnvironmentProvider
    private let session: URLSession
    private let timeout: TimeInterval

    /// Creates the client.
    /// - Parameters:
    ///   - baseURL: The selected backend origin, with or without a trailing slash.
    ///   - bundleID: The app's bundle id, sent as `x-cmux-bundle-id`.
    ///   - credentials: Reads the Stack session; nil means signed out.
    ///   - storeKitEnvironment: Reads the app's StoreKit environment, sent as
    ///     `x-cmux-storekit-environment`; nil omits the header.
    ///   - session: The URL session. Tests pass one with a stub protocol.
    ///   - timeout: Per-request deadline in seconds.
    ///   - backend: Explicit platform opt-in; does not infer a backend from a URL.
    public init(
        baseURL: String,
        bundleID: String,
        credentials: @escaping CredentialsProvider,
        storeKitEnvironment: @escaping EnvironmentProvider = { nil },
        session: URLSession,
        timeout: TimeInterval = 30,
        backend: Backend = .classic
    ) {
        self.backend = backend
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.bundleID = bundleID
        self.credentials = credentials
        self.storeKitEnvironment = storeKitEnvironment
        self.session = session
        self.timeout = timeout
    }

    public func accountToken() async throws -> BillingAccount {
        let request = try await accountTokenRequest()
        switch backend {
        case .classic:
            return try await send(request, decoding: BillingAccount.self)
        case .platform:
            let account = try await send(request, decoding: PlatformAccount.self)
            return BillingAccount(
                appAccountToken: account.appAccountToken,
                eligible: account.eligible,
                reason: account.reason,
                currentPlan: BillingCurrentPlan(
                    planID: account.current.planId ?? .free,
                    source: account.current.planId == nil ? .none : .apple
                ),
                products: account.products.map {
                    BillingProductReference(productID: $0.productId, planID: $0.planId, billingPeriod: $0.billingPeriod)
                },
                catalogFamily: .next
            )
        }
    }

    public func submitTransaction(signedTransactionInfo: String) async throws -> BillingTransactionReceipt {
        let request = try await transactionRequest(signedTransactionInfo: signedTransactionInfo)
        switch backend {
        case .classic:
            return try await send(request, decoding: BillingTransactionReceipt.self)
        case .platform:
            let receipt = try await send(request, decoding: PlatformReceipt.self)
            return BillingTransactionReceipt(
                planID: receipt.grants ? receipt.planId : .free,
                status: receipt.status,
                expiresAt: receipt.expiresAt.map {
                    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0 / 1_000))
                }
            )
        }
    }

    func accountTokenRequest() async throws -> URLRequest {
        switch backend {
        case .classic:
            return try await makeRequest(path: "/api/billing/apple/account-token", body: Data("{}".utf8))
        case .platform:
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let body = try encoder.encode(PlatformAccountRequest(bundleId: bundleID, environment: await storeKitEnvironment()))
            return try await makeRequest(path: "/v1/billing/apple/account-token", body: body)
        }
    }

    func transactionRequest(signedTransactionInfo: String) async throws -> URLRequest {
        let encoder = JSONEncoder()
        if backend == .platform { encoder.keyEncodingStrategy = .convertToSnakeCase }
        let body = try encoder.encode(TransactionBody(signedTransactionInfo: signedTransactionInfo))
        let prefix = backend == .platform ? "/v1" : "/api"
        return try await makeRequest(path: "\(prefix)/billing/apple/transactions", body: body)
    }

    public func paymentPastDue() async throws -> Bool {
        // cmux-platform has no `/api/billing/plan` and grants no web (Stripe) plans.
        guard backend == .classic else { return false }
        let request = try await makeRequest(path: "/api/billing/plan", method: "GET", body: nil)
        return Self.paymentPastDue(planReply: try await sendData(request))
    }

    /// `paymentPastDue` of a `GET /api/billing/plan` reply: true only for a
    /// JSON `true`. A missing field (an older server), another type or a body
    /// that is not JSON reads as false, as on the Mac.
    /// - Parameter data: The reply body.
    /// - Returns: Whether the latest renewal payment failed.
    static func paymentPastDue(planReply data: Data) -> Bool {
        struct Reply: Decodable { let paymentPastDue: Bool? }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.paymentPastDue == true
    }

    /// Builds a request; exposed to tests to pin the header contract.
    /// - Parameters:
    ///   - path: The route path, starting with `/`.
    ///   - method: The HTTP method, `POST` unless given.
    ///   - body: The JSON body; nil sends none.
    /// - Returns: The authenticated request.
    /// - Throws: ``BillingAPIError/notSignedIn`` or ``BillingAPIError/invalidURL``.
    func makeRequest(path: String, method: String = "POST", body: Data?) async throws -> URLRequest {
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
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(pair.accessToken)", forHTTPHeaderField: "Authorization")
        if backend == .classic {
            request.setValue(pair.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
            request.setValue(bundleID, forHTTPHeaderField: "x-cmux-bundle-id")
            // This client offers a Monthly/Yearly choice, so the server may list
            // yearly products; older clients do not send it and get monthly only.
            request.setValue("monthly,yearly", forHTTPHeaderField: "x-cmux-billing-periods")
            if let environment = await storeKitEnvironment() {
                request.setValue(environment, forHTTPHeaderField: "x-cmux-storekit-environment")
            }
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest, decoding: Response.Type) async throws -> Response {
        let data = try await sendData(request)
        do {
            let decoder = JSONDecoder()
            if backend == .platform { decoder.keyDecodingStrategy = .convertFromSnakeCase }
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw BillingAPIError.invalidResponse
        }
    }

    /// Sends `request` and returns a 2xx reply's body.
    private func sendData(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BillingAPIError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw BillingAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 403, let error = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                let mismatch = backend == .platform
                    ? error.code == "appstore.account_mismatch"
                    : error.error == "account_mismatch"
                if mismatch { throw BillingAPIError.accountMismatch }
            }
            throw BillingAPIError.rejected(statusCode: http.statusCode)
        }
        return data
    }

    private struct TransactionBody: Encodable {
        let signedTransactionInfo: String
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let code: String?
    }

    private struct PlatformAccountRequest: Encodable {
        let bundleId: String
        let environment: String?
    }

    private struct PlatformAccount: Decodable {
        let appAccountToken: UUID
        let eligible: Bool
        let reason: BillingIneligibilityReason?
        let current: PlatformCurrent
        let products: [PlatformProduct]
    }

    private struct PlatformCurrent: Decodable {
        let planId: BillingPlanID?
    }

    private struct PlatformProduct: Decodable {
        let productId: String
        let planId: BillingPlanID
        let billingPeriod: BillingPeriod
    }

    private struct PlatformReceipt: Decodable {
        let planId: BillingPlanID
        let status: String
        let expiresAt: Double?
        let grants: Bool
    }
}
