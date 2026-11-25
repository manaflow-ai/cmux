#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import Foundation

/// Localized name and feature bullets for one cmux plan, matching the web
/// pricing page. NEXT allowances follow RFD 0037 and `NEXT_PLAN_OFFERS`
/// (web/services/billing/nextPlans.ts); keep the two in step.
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
        case .nextPlus: L10n.string("mobile.billing.plan.next_plus", defaultValue: "Plus")
        case .nextPro: L10n.string("mobile.billing.plan.pro", defaultValue: "Pro")
        case .nextMax: L10n.string("mobile.billing.plan.max", defaultValue: "Max")
        default: planID.rawValue.capitalized
        }
    }

    /// The plan's Cloud VM allowances, one line each.
    var features: [String] {
        switch planID {
        case .go:
            [
                L10n.string("mobile.billing.plan.go.machines", defaultValue: "1 Cloud VM"),
                L10n.string("mobile.billing.plan.go.largest", defaultValue: "Up to 8 vCPUs and 16 GB RAM"),
            ]
        case .pro:
            [
                L10n.string("mobile.billing.plan.pro.machines", defaultValue: "Up to 5 Cloud VMs"),
                L10n.string("mobile.billing.plan.pro.size", defaultValue: "Sharing 20 vCPUs and 40 GB RAM"),
            ]
        case .max:
            [
                L10n.string("mobile.billing.plan.max.machines", defaultValue: "Up to 5 Cloud VMs"),
                L10n.string("mobile.billing.plan.max.size", defaultValue: "Sharing 80 vCPUs and 160 GB RAM"),
            ]
        case .nextPlus:
            [
                L10n.string("mobile.billing.plan.next_plus.minutes", defaultValue: "30,000 machine-minutes a month"),
                L10n.string("mobile.billing.plan.next_plus.largest", defaultValue: "Machines up to 4 vCPUs and 16 GB RAM"),
                L10n.string("mobile.billing.plan.next_plus.chiefs", defaultValue: "1 Chief"),
            ]
        case .nextPro:
            [
                L10n.string("mobile.billing.plan.next_pro.minutes", defaultValue: "75,000 machine-minutes a month"),
                L10n.string("mobile.billing.plan.next_pro.largest", defaultValue: "Machines up to 8 vCPUs and 32 GB RAM"),
                L10n.string("mobile.billing.plan.next_pro.chiefs", defaultValue: "2 Chiefs"),
            ]
        case .nextMax:
            [
                L10n.string("mobile.billing.plan.next_max.minutes", defaultValue: "300,000 machine-minutes a month"),
                L10n.string("mobile.billing.plan.next_max.largest", defaultValue: "Machines up to 32 vCPUs and 64 GB RAM"),
                L10n.string("mobile.billing.plan.next_max.chiefs", defaultValue: "5 Chiefs"),
            ]
        default:
            []
        }
    }
}
#endif
