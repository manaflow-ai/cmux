#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import Foundation

/// Localized name and feature bullets for one cmux plan, matching the web
/// pricing page.
struct BillingPlanCopy: Equatable {
    /// The plan this copy describes.
    let planID: BillingPlanID

    /// The localized plan name; an unknown plan shows its capitalized id.
    var name: String {
        switch planID {
        case .free: L10n.string("mobile.billing.plan.free", defaultValue: "Free")
        case .go: L10n.string("mobile.billing.plan.go", defaultValue: "Go")
        case .pro: L10n.string("mobile.billing.plan.pro", defaultValue: "Pro")
        case .max: L10n.string("mobile.billing.plan.max", defaultValue: "Max")
        default: planID.rawValue.capitalized
        }
    }

    /// The plan's Cloud VM allowances, one line each.
    var features: [String] {
        switch planID {
        case .go:
            [
                L10n.string("mobile.billing.plan.go.machines", defaultValue: "1 Cloud VM"),
                L10n.string("mobile.billing.plan.go.size", defaultValue: "2 vCPUs and 4 GB RAM"),
                L10n.string("mobile.billing.plan.go.hours", defaultValue: "40 VM-hours a month"),
            ]
        case .pro:
            [
                L10n.string("mobile.billing.plan.pro.machines", defaultValue: "Up to 5 Cloud VMs"),
                L10n.string("mobile.billing.plan.pro.size", defaultValue: "Up to 4 vCPUs and 8 GB RAM per VM"),
            ]
        case .max:
            [
                L10n.string("mobile.billing.plan.max.machines", defaultValue: "Up to 5 Cloud VMs"),
                L10n.string("mobile.billing.plan.max.size", defaultValue: "Up to 16 vCPUs and 32 GB RAM per VM"),
            ]
        default:
            []
        }
    }
}
#endif
