import CmuxNextCloud
import Foundation
import Testing

/// A create the plan does not include comes back as the typed Pro refusal the
/// app turns into its Upgrade to cmux Pro dialog; a paid plan's ordinary limit
/// stays a plain HTTP refusal. Bodies are the server's own (web/services/vms/routeHelpers.ts).
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

    private func create(answering body: String) async -> (any Error)? {
        RefusingAPI.body = body
        let configuration = CloudConfiguration.resolve(
            bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"], process: [:], isDebugBuild: true)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RefusingAPI.self]
        let api = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { "team-1" },
                                 session: URLSession(configuration: sessionConfiguration))
        do {
            _ = try await api.createMachine(displayName: nil)
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

    @Test func aProBudgetThatNamesMaxStaysAnHTTPRefusal() async {
        let error = await create(answering: #"""
            {"error":"vm_compute_budget_reached","message":"This month's compute budget is used up.",
             "upgradeRequired":true,"upgradePlanId":"max","upgradeUrl":"https://cmux.com/api/billing/checkout?plan=max"}
            """#)
        #expect(error as? CloudAPIError == .http(status: 402, code: "vm_compute_budget_reached",
                                                  message: "This month's compute budget is used up."))
    }

    @Test func aPaidPlansLimitStaysAnHTTPRefusal() async {
        let error = await create(answering: #"""
            {"error":"vm_active_limit_exceeded","message":"This plan allows 3 active Cloud VMs at a time.","limit":3,"details":{"limit":3}}
            """#)
        #expect(error as? CloudAPIError == .http(status: 402, code: "vm_active_limit_exceeded",
                                                  message: "This plan allows 3 active Cloud VMs at a time."))
    }
}
