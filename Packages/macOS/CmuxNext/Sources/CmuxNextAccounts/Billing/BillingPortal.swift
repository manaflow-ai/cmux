package import Foundation

/// The account's billing page on cmux.com (`dashboard/billing`), the team's with `team`: what
/// `cmux billing portal` and Manage Billing (`billing.openPortal`) open.
package nonisolated enum BillingPortal {
    package static func url(base: URL, team: String?) -> URL? {
        var components = URLComponents(url: base.appending(path: "dashboard/billing"), resolvingAgainstBaseURL: false)
        if let team, !team.isEmpty {
            components?.queryItems = [URLQueryItem(name: "team", value: team)]
        }
        return components?.url
    }
}
