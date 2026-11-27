@testable import CmuxNextCloud
import CmuxNextCompat
import Foundation
import Testing

/// A request the plan does not include comes back as the typed plan refusal (Pro
/// for the app's Upgrade to cmux Pro dialog, Max for a Pro plan's limits); a paid
/// plan's ordinary limit and a credits top-up stay plain HTTP refusals. Bodies are the server's own (web/services/vms/routeHelpers.ts).
@Suite(.serialized)
struct CloudAPIClientPlanRequiredTests {
    /// A refusal as the app's own HTTP routes read it (``CloudAPIError/from(status:data:headerCode:)``). The machine
    /// routes (a desktop setup, a Run's cancel) are the daemon's now, whose Rust reads those bodies the same way
    /// (cmux-cloud-machine's error tests, cmux-cloud-api's `a_desktop_setup_refusal_reads_as_a_machine_routes`).
    private func create(answering body: String) async -> (any Error)? {
        CloudAPIError.from(status: 402, data: Data(body.utf8), headerCode: nil)
    }

    /// A desktop setup is the daemon's `machine.setup_desktop`, and its plan refusal comes back typed.
    @Test func aDesktopSetupIsTheDaemonsCallAndItsPlanRefusalIsTyped() async throws {
        let seen = Mutex<Data?>(nil)
        guard let baseURL = URL(string: "https://vm-api.standin.invalid") else { return }
        var api = CloudAPIClient.workerMachines(baseURL: baseURL, accessToken: { "access" }, teamID: { "team-1" })
        api.daemon.daemonCall = { input, _ in
            seen.withLock { $0 = input }
            return Data(#"{"ok":false,"error":{"kind":"plan_required","message":"Cloud VMs require a cmux Pro subscription.","upgrade_url":"https://cmux.com/pricing","plan":"pro"}}"#.utf8)
        }
        await #expect(throws: CloudAPIError.planRequired(message: "Cloud VMs require a cmux Pro subscription.",
                                                         upgradeURL: URL(string: "https://cmux.com/pricing"))) {
            try await api.setupDesktop("vm_aaaaaaaaaaaaaaaaaaaa")
        }
        let body = try #require(seen.withLock { $0 })
        let request = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(request["call"] as? String == "machine.setup_desktop")
        #expect(request["auth"] as? String == "owner")
        #expect(request["credential"] as? String == "access")
        #expect((request["args"] as? [String: Any])?["id"] as? String == "vm_aaaaaaaaaaaaaaaaaaaa")
        api.daemon.daemonCall = { _, _ in Data(#"{"ok":true,"body":{"ok":true}}"#.utf8) }
        try await api.setupDesktop("vm_aaaaaaaaaaaaaaaaaaaa")
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
