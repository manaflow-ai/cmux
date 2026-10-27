package import Foundation

/// The body of `POST /api/billing/checkout` (web, native checkout): the plan,
/// and the team for a Team plan. Go stays a classic plan.
package nonisolated struct BillingCheckoutRequest: Sendable {
    package struct Invalid: Error, Sendable, CustomStringConvertible {
        package let description: String

        package init(description: String) {
            self.description = description
        }
    }

    package let plan: String
    package let team: String?

    package init(plan: String, team: String?) throws {
        guard ["pro", "max", "team"].contains(plan) else { throw Invalid(description: BillingStrings.badPlan) }
        let team = team?.trimmingCharacters(in: .whitespacesAndNewlines)
        if plan == "team", team?.isEmpty ?? true { throw Invalid(description: BillingStrings.teamRequired) }
        self.plan = plan
        self.team = plan == "team" ? team : nil
    }

    package var body: [String: any Sendable] {
        var body: [String: any Sendable] = ["plan": plan]
        if let team { body["teamId"] = team }
        return body
    }
}
