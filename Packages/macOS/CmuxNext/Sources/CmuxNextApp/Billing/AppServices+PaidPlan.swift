import AppKit
import CmuxNextAccounts
import CmuxNextPages
import Foundation

// The composition of the paid-plan path (plans/cmux-next/paid-plans-DESIGN.md §2): every paywall
// calls `paidPlanUpgrade().start(...)`; the Cloud list's plan read feeds the welcome step.
extension AppServices {
    /// The upgrade path over this app's cmux.com sign-in and callback scheme.
    func paidPlanUpgrade() -> PaidPlanUpgrade {
        var checkout: (@MainActor (String, String) async throws -> URL)?
        if cloud.isSignedIn, let client = accounts.client {
            checkout = { plan, scheme in
                let body = try BillingCheckoutRequest(plan: plan, team: nil, scheme: scheme).body
                let data = try await client.request("POST", "/api/billing/checkout", body: body)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let raw = object["url"] as? String, let url = URL(string: raw) else { throw URLError(.badServerResponse) }
                return url
            }
        }
        return PaidPlanUpgrade(checkout: checkout, open: { LinkRouter.shared.open($0) },
                               scheme: cloud.configuration.callbackScheme, onboarding: paidPlanOnboarding)
    }

    /// The welcome step's state, in the app's defaults.
    var paidPlanOnboarding: PaidPlanOnboarding { PaidPlanOnboarding(defaults: .standard) }

    /// Shows the welcome card once when the plan the Cloud list read turned paid after an upgrade.
    func paidPlanObserved(_ planID: String?) {
        guard let account = cloud.auth.user?.id, let welcome = paidPlanOnboarding.observe(planID: planID, account: account) else { return }
        // task-owner: one welcome card, ends when the person answers it
        Task { @MainActor [weak self] in
            guard let self else { return }
            let start = await machineAsks.ask(PaidPlanStrings.welcomeTitle(welcome.plan), detail: PaidPlanStrings.welcomeDetail, symbol: "sparkles",
                                              yes: PaidPlanStrings.startCloud, no: PaidPlanStrings.later)
            if start { _ = registry.perform("newCloudWorkspace") }
        }
    }

    /// While an upgrade waits for its payment, coming back to the app reads the plan again.
    func followPaidPlanReturns() {
        // task-owner: app-lifetime activation watch; ends with the process
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let self, paidPlanOnboarding.hasPending else { continue }
                await cloud.refresh()
            }
        }
    }
}
