import Foundation

/// User-facing messages of the `billing.*` control methods (`cmux billing`).
/// Keys live in Resources/Billing.xcstrings (en, ja).
nonisolated enum BillingStrings {
    static var liveOff: String { String(localized: "billing.error.liveOff", defaultValue: "Live checkout from cmux-next is not on yet. Open https://cmux.com/pricing to buy a plan.", table: "Billing", bundle: .module) }
    static var notSignedIn: String { String(localized: "billing.error.notSignedIn", defaultValue: "Sign in to cmux in the cmux app first.", table: "Billing", bundle: .module) }
    static var unavailable: String { String(localized: "billing.error.unavailable", defaultValue: "Billing is not available in this build.", table: "Billing", bundle: .module) }
    static var badResponse: String { String(localized: "billing.error.badResponse", defaultValue: "cmux.com sent no checkout page; retry in a minute.", table: "Billing", bundle: .module) }
    static var badOpen: String { String(localized: "billing.error.badOpen", defaultValue: "`open` must be auto, cmux, default or none.", table: "Billing", bundle: .module) }
    static var badPlan: String { String(localized: "billing.error.badPlan", defaultValue: "`plan` must be pro, max or team.", table: "Billing", bundle: .module) }
    static var teamRequired: String { String(localized: "billing.error.teamRequired", defaultValue: "A Team checkout needs `teamId` (a team you administer).", table: "Billing", bundle: .module) }
}
