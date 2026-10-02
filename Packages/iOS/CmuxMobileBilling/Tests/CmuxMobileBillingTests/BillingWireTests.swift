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
        #expect(BillingFailure(StoreKitClientError.purchasesNotAllowed) == .purchasesNotAllowed)
        #expect(BillingFailure.server(statusCode: 503).analyticsReason == "server_503")
    }
}
