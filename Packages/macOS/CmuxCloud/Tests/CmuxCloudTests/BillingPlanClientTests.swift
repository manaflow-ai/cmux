import CmuxCloud
import Foundation
import Testing

/// The plan endpoint answers an unauthenticated request (no token, or a token
/// it cannot read) with `authenticated: false` and a free plan. That reply says
/// nothing about the signed-in account, so it must not become a known Free plan
/// that turns the Cloud Enable step into Upgrade (#20051).
@Suite("Billing plan client", .serialized)
struct BillingPlanClientTests {
    @Test("unauthenticated reply is a failure, not a free plan")
    func unauthenticatedReplyThrows() async {
        let client = BillingPlanClient(session: BillingPlanStubURLProtocol.session(body: """
        {"authenticated":false,"planId":"free","isPro":false,"billingManagement":"none",
         "teamPlanId":"free","teamBillingManagement":"none","user":null}
        """))

        await #expect(throws: (any Error).self) {
            _ = try await client.fetch(from: BillingPlanStubURLProtocol.url, accessToken: nil)
        }
    }

    @Test("authenticated team plan grants Cloud access")
    func authenticatedTeamPlanIsPro() async throws {
        let client = BillingPlanClient(session: BillingPlanStubURLProtocol.session(body: """
        {"authenticated":true,"planId":"free","isPro":false,"billingManagement":"none",
         "teamPlanId":"pro","teamBillingManagement":"stripe"}
        """))

        let details = try await client.fetch(from: BillingPlanStubURLProtocol.url, accessToken: "token")
        #expect(details.isPro)
        #expect(details.canManageBilling)
    }
}

final class BillingPlanStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let url = URL(string: "https://billing-plan.test/api/billing/plan")!
    nonisolated(unsafe) static var body = Data()

    static func session(body: String) -> URLSession {
        self.body = Data(body.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillingPlanStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
