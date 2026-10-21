import CMUXMobileCore
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

        await #expect(throws: URLError(.userAuthenticationRequired)) {
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

    // The Settings plan row names who bills the plan; App Store and granted
    // plans must not read as a Stripe-managed subscription.
    @Test("billing source decodes", arguments: [
        ("\"billingSource\":\"apple\",", BillingSource.apple as BillingSource?),
        ("\"billingSource\":\"stripe\",", BillingSource.stripe as BillingSource?),
        ("\"billingSource\":\"none\",", BillingSource.unbilled as BillingSource?),
        ("\"billingSource\":\"unknown\",", nil),
        ("", nil),
    ])
    func billingSourceDecodes(field: String, expected: BillingSource?) async throws {
        let client = BillingPlanClient(session: BillingPlanStubURLProtocol.session(body: """
        {"authenticated":true,"planId":"pro","subscriptionPlanId":"pro",\(field)
         "isPro":true,"billingManagement":"external","teamPlanId":"free","teamBillingManagement":"none"}
        """))

        let details = try await client.fetch(from: BillingPlanStubURLProtocol.url, accessToken: "token")
        #expect(details.billingSource == expected)
        let state = BillingPlanState.unknown.applyingSuccess(
            for: "user-1", isPro: details.isPro, canManageBilling: details.canManageBilling,
            tier: details.tier, billingSource: details.billingSource
        )
        #expect(state.billingSource == expected)
    }

    // A Max subscriber is reported as planId "pro" for older clients. The
    // exact plan must survive decoding, or Max reads as Pro and the app
    // offers an upgrade the account already has.
    @Test("Max subscriber decodes as the Max tier", arguments: [
        ("free", "free", "free", false, CmuxPlanTier.free),
        ("go", "pro", "free", true, CmuxPlanTier.go),
        ("pro", "pro", "free", true, CmuxPlanTier.pro),
        ("max", "pro", "free", true, CmuxPlanTier.max),
        ("free", "free", "team", false, CmuxPlanTier.pro),
    ])
    func exactTierDecodes(
        subscriptionPlanID: String,
        planID: String,
        teamPlanID: String,
        isPro: Bool,
        expected: CmuxPlanTier
    ) async throws {
        let client = BillingPlanClient(session: BillingPlanStubURLProtocol.session(body: """
        {"authenticated":true,"planId":"\(planID)","subscriptionPlanId":"\(subscriptionPlanID)",
         "isPro":\(isPro),"billingManagement":"stripe","teamPlanId":"\(teamPlanID)","teamBillingManagement":"none"}
        """))

        let details = try await client.fetch(from: BillingPlanStubURLProtocol.url, accessToken: "token")
        #expect(details.tier == expected)
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
