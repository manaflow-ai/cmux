import CmuxNextCloud
import Foundation
import Testing

/// A request the plan does not include comes back as the typed plan refusal (Pro
/// for the app's Upgrade to cmux Pro dialog, Max for a Pro plan's limits); a paid
/// plan's ordinary limit and a credits top-up stay plain HTTP refusals. Bodies are the server's own (web/services/vms/routeHelpers.ts).
@Suite(.serialized)
struct CloudAPIClientPlanRequiredTests {
    nonisolated final class RefusingAPI: URLProtocol {
        nonisolated(unsafe) static var body = ""

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 402, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// A refusal of a route the app still sends over HTTP itself: a Worker machines client's
    /// desktop setup. (A Run's cancel was this route until #39022 moved the runs.* calls into the
    /// daemon, whose Rust reads those bodies: cmux-cloud-api's tests.)
    private func create(answering body: String) async -> (any Error)? {
        RefusingAPI.body = body
        guard let baseURL = URL(string: "https://vm-api.standin.invalid") else { return nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RefusingAPI.self]
        let api = CloudAPIClient.workerMachines(baseURL: baseURL, accessToken: { "access" },
                                                teamID: { "team-1" }, session: URLSession(configuration: sessionConfiguration))
        do {
            try await api.setupDesktop("vm-1")
            return nil
        } catch {
            return error
        }
    }

    @Test func aFreeAccountsCreateIsThePlanRefusal() async {
        let error = await create(answering: #"""
            {"error":"vm_active_limit_exceeded","message":"Cloud VMs require a cmux Pro subscription.",
             "limit":0,"upgradeRequired":true,"upgradeUrl":"https://cmux.com/pricing","details":{"limit":0,"upgradeRequired":true}}
            """#)
        #expect(error as? CloudAPIError == .planRequired(message: "Cloud VMs require a cmux Pro subscription.",
                                                          upgradeURL: URL(string: "https://cmux.com/pricing")))
    }

    @Test func aProBudgetThatNamesMaxIsAMaxPlanRefusal() async {
        let error = await create(answering: #"""
            {"error":"vm_compute_budget_reached","message":"This month's compute budget is used up.",
             "upgradeRequired":true,"upgradePlanId":"max","upgradeUrl":"https://cmux.com/api/billing/checkout?plan=max"}
            """#)
        #expect(error as? CloudAPIError == .planRequired(message: "This month's compute budget is used up.",
                                                          upgradeURL: URL(string: "https://cmux.com/api/billing/checkout?plan=max"),
                                                          plan: "max"))
    }

    @Test func aCreditsTopUpStaysAnHTTPRefusal() async {
        let error = await create(answering: #"""
            {"error":"vm_create_credits_insufficient","message":"You are out of Cloud credits.",
             "upgradeRequired":true,"upgradePlanId":"max","upgradeUrl":"https://cmux.com/api/billing/checkout?plan=max"}
            """#)
        #expect(error as? CloudAPIError == .http(status: 402, code: "vm_create_credits_insufficient",
                                                  message: "You are out of Cloud credits."))
    }

    @Test func aPaidPlansLimitStaysAnHTTPRefusal() async {
        let error = await create(answering: #"""
            {"error":"vm_active_limit_exceeded","message":"This plan allows 3 active Cloud VMs at a time.","limit":3,"details":{"limit":3}}
            """#)
        #expect(error as? CloudAPIError == .http(status: 402, code: "vm_active_limit_exceeded",
                                                  message: "This plan allows 3 active Cloud VMs at a time."))
    }
}
