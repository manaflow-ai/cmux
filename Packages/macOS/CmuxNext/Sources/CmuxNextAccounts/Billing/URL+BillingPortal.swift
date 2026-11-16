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
}
