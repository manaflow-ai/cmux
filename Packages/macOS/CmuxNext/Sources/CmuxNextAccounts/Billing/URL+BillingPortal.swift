package import Foundation

extension URL {
    /// The account's billing page under this cmux.com base (`dashboard/billing`), the team's with
    /// `team`: what `cmux billing portal` and Manage Billing (`billing.openPortal`) open.
    package nonisolated func billingPortal(team: String?) -> URL? {
        var components = URLComponents(url: appending(path: "dashboard/billing"), resolvingAgainstBaseURL: false)
        if let team, !team.isEmpty {
            components?.queryItems = [URLQueryItem(name: "team", value: team)]
        }
        return components?.url
    }

    /// cmux.com's checkout page for `plan` under this base (`api/billing/checkout?plan=`): it signs the person in, then
    /// opens the plan's payment page. What a cmux NEXT plan's Subscribe opens (``PaidPlanUpgrade``).
    package nonisolated func billingCheckout(plan: String) -> URL? {
        var components = URLComponents(url: appending(path: "api/billing/checkout"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "plan", value: plan)]
        return components?.url
    }
}
