import Foundation

/// The paid-plan welcome card's text (table `PaidPlans`, English and Japanese).
enum PaidPlanStrings {
    static func welcomeTitle(_ plan: String) -> String {
        String(format: String(localized: "paidPlans.welcome.title", defaultValue: "Welcome to %@", table: "PaidPlans", bundle: .module), planName(plan))
    }

    static var welcomeDetail: String {
        String(localized: "paidPlans.welcome.detail", defaultValue: "Your plan is active. Start a Cloud machine, or see your usage and invoices on the billing page.", table: "PaidPlans", bundle: .module)
    }

    static var startCloud: String { String(localized: "paidPlans.welcome.start", defaultValue: "New Cloud Workspace", table: "PaidPlans", bundle: .module) }
    static var later: String { String(localized: "paidPlans.welcome.later", defaultValue: "Later", table: "PaidPlans", bundle: .module) }

    static func planName(_ plan: String) -> String {
        switch plan {
        case "max": String(localized: "paidPlans.plan.max", defaultValue: "cmux Max", table: "PaidPlans", bundle: .module)
        case "team": String(localized: "paidPlans.plan.team", defaultValue: "cmux Team", table: "PaidPlans", bundle: .module)
        case "go": String(localized: "paidPlans.plan.go", defaultValue: "cmux Go", table: "PaidPlans", bundle: .module)
        default: String(localized: "paidPlans.plan.pro", defaultValue: "cmux Pro", table: "PaidPlans", bundle: .module)
        }
    }
}
