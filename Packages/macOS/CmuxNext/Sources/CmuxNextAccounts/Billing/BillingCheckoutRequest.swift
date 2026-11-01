package import Foundation

/// The body of `POST /api/billing/checkout` (web, native checkout): the plan,
/// the team for a Team plan, and the app's callback scheme, so the success page's "Open cmux"
/// returns to the app that started the checkout (cmux NEXT, a tagged build) instead of classic
/// `cmux://`. Plan ids are web billing's: `go` is cmux Plus ($15/mo), then pro, max and team.
package nonisolated struct BillingCheckoutRequest: Sendable {
    package struct Invalid: Error, Sendable, CustomStringConvertible {
        package let description: String

        package init(description: String) {
            self.description = description
        }
    }

    package let plan: String
    package let team: String?
    /// The callback scheme cmux.com sends the person back to (`cmux_scheme`); nil keeps its default.
    package let scheme: String?

    package init(plan: String, team: String?, scheme: String? = nil) throws {
        guard ["go", "pro", "max", "team"].contains(plan) else { throw Invalid(description: BillingStrings.badPlan) }
        let team = team?.trimmingCharacters(in: .whitespacesAndNewlines)
        if plan == "team", team?.isEmpty ?? true { throw Invalid(description: BillingStrings.teamRequired) }
        self.plan = plan
        self.team = plan == "team" ? team : nil
        self.scheme = scheme.flatMap { $0.isEmpty ? nil : $0 }
    }

    package var body: [String: any Sendable] {
        var body: [String: any Sendable] = ["plan": plan]
        if let team { body["teamId"] = team }
        if let scheme { body["cmux_scheme"] = scheme }
        return body
    }
}
