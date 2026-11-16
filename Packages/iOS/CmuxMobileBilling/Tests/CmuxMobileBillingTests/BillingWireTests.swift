import Foundation
import Testing
@testable import CmuxMobileBilling

@Suite struct BillingWireTests {
    @Test func decodesAccountTokenResponse() throws {
        let json = Data("""
        {
          "appAccountToken": "6f9619ff-8b86-d011-b42d-00c04fc964ff",
          "eligible": true,
          "reason": null,
          "currentPlan": { "planId": "free", "source": "none" },
          "products": [
            { "productId": "com.cmux.app.pro.monthly", "planId": "pro" },
            { "productId": "com.cmux.app.max.monthly", "planId": "MAX" }
          ]
        }
        """.utf8)
        let account = try JSONDecoder().decode(BillingAccount.self, from: json)
        #expect(account.appAccountToken == BillingFixtures.token)
        #expect(account.eligible)
        #expect(account.reason == nil)
        #expect(account.currentPlan == BillingCurrentPlan(planID: .free, source: .none))
        #expect(account.products.map(\.planID) == [.pro, .max])
    }

    @Test func decodesIneligibleResponseWithoutProducts() throws {
        let json = Data("""
        {
          "appAccountToken": "6f9619ff-8b86-d011-b42d-00c04fc964ff",
          "eligible": false,
          "reason": "team_billing",
          "currentPlan": { "planId": "pro", "source": "stripe", "manageUrl": "https://cmux.com/billing" }
        }
        """.utf8)
        let account = try JSONDecoder().decode(BillingAccount.self, from: json)
        #expect(account.reason == .teamBilling)
        #expect(account.currentPlan.source == .stripe)
        #expect(account.products.isEmpty)
    }

    @Test func decodesPurchasesUnavailableReason() throws {
        let json = Data("""
        {
          "appAccountToken": "6f9619ff-8b86-d011-b42d-00c04fc964ff",
          "eligible": false,
          "reason": "purchases_unavailable",
          "currentPlan": { "planId": "free", "source": "none" },
          "products": []
        }
        """.utf8)
        let account = try JSONDecoder().decode(BillingAccount.self, from: json)
        #expect(account.reason == .purchasesUnavailable)
        #expect(account.products.isEmpty)
    }

    @Test func requestCarriesStoreKitEnvironmentWhenKnown() async throws {
        let sandbox = HTTPBillingAPI(
            baseURL: "https://cmux.example",
            bundleID: "dev.cmux.app.beta",
            credentials: { BillingAPICredentials(accessToken: "access", refreshToken: "refresh") },
            storeKitEnvironment: { "Sandbox" },
            session: URLSession(configuration: .ephemeral)
        )
        let request = try await sandbox.makeRequest(path: "/api/billing/apple/account-token", body: Data("{}".utf8))
        #expect(request.value(forHTTPHeaderField: "x-cmux-storekit-environment") == "Sandbox")

        let unknown = HTTPBillingAPI(
            baseURL: "https://cmux.example",
            bundleID: "dev.cmux.app.beta",
            credentials: { BillingAPICredentials(accessToken: "access", refreshToken: "refresh") },
            session: URLSession(configuration: .ephemeral)
        )
        let bare = try await unknown.makeRequest(path: "/api/billing/apple/account-token", body: Data("{}".utf8))
        #expect(bare.value(forHTTPHeaderField: "x-cmux-storekit-environment") == nil)
    }

    @Test func requestCarriesStackAuthAndBundleHeaders() async throws {
        let api = HTTPBillingAPI(
            baseURL: "https://cmux.example/",
            bundleID: "com.cmux.app",
            credentials: { BillingAPICredentials(accessToken: "access", refreshToken: "refresh") },
            session: URLSession(configuration: .ephemeral)
        )
        let request = try await api.makeRequest(path: "/api/billing/apple/transactions", body: Data("{}".utf8))
        #expect(request.url?.absoluteString == "https://cmux.example/api/billing/apple/transactions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(request.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh")
        #expect(request.value(forHTTPHeaderField: "x-cmux-bundle-id") == "com.cmux.app")
    }

    @Test func signedOutRequestIsNotBuilt() async throws {
        let api = HTTPBillingAPI(
            baseURL: "https://cmux.example",
            bundleID: "com.cmux.app",
            credentials: { nil },
            session: URLSession(configuration: .ephemeral)
        )
        await #expect(throws: BillingAPIError.notSignedIn) {
            _ = try await api.makeRequest(path: "/api/billing/apple/account-token", body: Data())
        }
    }

    @Test func failureClassificationMapsAPIAndStoreErrors() {
        #expect(BillingFailure(BillingAPIError.transport) == .network)
        #expect(BillingFailure(BillingAPIError.rejected(statusCode: 409)) == .server(statusCode: 409))
        #expect(BillingFailure(BillingAPIError.accountMismatch) == .accountMismatch)
        #expect(BillingFailure(StoreKitClientError.purchasesNotAllowed) == .purchasesNotAllowed)
        #expect(BillingFailure.server(statusCode: 503).analyticsReason == "server_503")
        #expect(BillingFailure.accountMismatch.analyticsReason == "account_mismatch")
    }

    @Test func onlyClientErrorsThatRetryingCannotFixArePermanent() {
        for status in [400, 403, 404, 409, 422] {
            #expect(BillingFailure.server(statusCode: status).isPermanentRejection, "status \(status)")
        }
        for status in [401, 408, 429, 500, 503] {
            #expect(!BillingFailure.server(statusCode: status).isPermanentRejection, "status \(status)")
        }
        #expect(BillingFailure.accountMismatch.isPermanentRejection)
        #expect(!BillingFailure.network.isPermanentRejection)
        #expect(!BillingFailure.notSignedIn.isPermanentRejection)
    }

    @Test func accountMismatchBodyIsDistinguishedFromOther403s() async throws {
        let mismatch = StubURLProtocol.api(host: "mismatch.example", status: 403, body: #"{"error":"account_mismatch"}"#)
        await #expect(throws: BillingAPIError.accountMismatch) {
            _ = try await mismatch.submitTransaction(signedTransactionInfo: "jws")
        }
        let forbidden = StubURLProtocol.api(host: "forbidden.example", status: 403, body: "<html>denied</html>")
        await #expect(throws: BillingAPIError.rejected(statusCode: 403)) {
            _ = try await forbidden.submitTransaction(signedTransactionInfo: "jws")
        }
    }
}

/// Answers every request to a host with a fixed status and body.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (Int, Data)] = [:]

    /// An API whose requests to `host` get `status` and `body`.
    static func api(host: String, status: Int, body: String) -> HTTPBillingAPI {
        lock.withLock { responses[host] = (status, Data(body.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return HTTPBillingAPI(
            baseURL: "https://\(host)",
            bundleID: "com.cmux.app",
            credentials: { BillingAPICredentials(accessToken: "access", refreshToken: "refresh") },
            session: URLSession(configuration: configuration)
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let (status, body) = Self.lock.withLock({ Self.responses[host] }),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
