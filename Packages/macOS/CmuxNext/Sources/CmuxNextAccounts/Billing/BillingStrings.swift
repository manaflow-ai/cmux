package import Foundation

/// User-facing messages of the `billing.*` control methods (`cmux billing`).
/// Keys live in Resources/Billing.xcstrings (en, ja).
package nonisolated struct BillingStrings {
    package nonisolated init() {}
    /// The bundle that holds `Resources/Billing.xcstrings` (this module's), for tests.
    package static var bundle: Bundle { .module }
    package static var liveOff: String { String(localized: "billing.error.liveOff", defaultValue: "Live checkout from cmux-next is not on yet. Open https://cmux.com/pricing to buy a plan.", table: "Billing", bundle: .module) }
    package static var notSignedIn: String { String(localized: "billing.error.notSignedIn", defaultValue: "Sign in to cmux in the cmux app first.", table: "Billing", bundle: .module) }
    package static var unavailable: String { String(localized: "billing.error.unavailable", defaultValue: "Billing is not available in this build.", table: "Billing", bundle: .module) }
    package static var badResponse: String { String(localized: "billing.error.badResponse", defaultValue: "cmux.com sent no checkout page; retry in a minute.", table: "Billing", bundle: .module) }
    package static var badOpen: String { String(localized: "billing.error.badOpen", defaultValue: "`open` must be auto, cmux, default or none.", table: "Billing", bundle: .module) }
    package static var badPlan: String { String(localized: "billing.error.badPlan", defaultValue: "`plan` must be go, pro, max or team.", table: "Billing", bundle: .module) }
    package static var teamRequired: String { String(localized: "billing.error.teamRequired", defaultValue: "A Team checkout needs `teamId` (a team you administer).", table: "Billing", bundle: .module) }
}

extension BillingStrings {
    /// The paid-plan welcome card (``PaidPlanWelcome``).
    package static func welcomeTitle(_ plan: String) -> String {
        String(format: String(localized: "billing.welcome.title", defaultValue: "Welcome to %@", table: "Billing", bundle: .module), planName(plan))
    }

    package static var welcomeDetail: String {
        String(localized: "billing.welcome.detail", defaultValue: "Your plan is active. Start a Cloud machine, or see your usage and invoices on the billing page.", table: "Billing", bundle: .module)
    }

    package static var welcomeStart: String { String(localized: "billing.welcome.start", defaultValue: "New Cloud Workspace", table: "Billing", bundle: .module) }
    package static var welcomeLater: String { String(localized: "billing.welcome.later", defaultValue: "Later", table: "Billing", bundle: .module) }

    /// The plan's product name (a brand name, the same in every language).
    package static func planName(_ plan: String) -> String {
        switch plan {
        case "max": "cmux Max"
        case "team": "cmux Team"
        case "go": "cmux Plus"
        default: "cmux Pro"
        }
    }
}
