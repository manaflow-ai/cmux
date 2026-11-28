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

    /// One plan's value in a comparison row; nil means not included.
    func comparisonValue(_ row: BillingComparisonRow) -> String? {
        switch (row, planID) {
        case (.machines, .go): "1"
        case (.machines, .pro), (.machines, .max):
            L10n.string("mobile.billing.compare.upTo5", defaultValue: "Up to 5")
        case (.sharedCPU, .go): "2"
        case (.sharedCPU, .pro): "20"
        case (.sharedCPU, .max): "80"
        case (.sharedMemory, .go): L10n.string("mobile.billing.compare.go.memory", defaultValue: "4 GB")
        case (.sharedMemory, .pro): L10n.string("mobile.billing.compare.pro.memory", defaultValue: "40 GB")
        case (.sharedMemory, .max): L10n.string("mobile.billing.compare.max.memory", defaultValue: "160 GB")
        case (.largestMachine, .go):
            L10n.string("mobile.billing.compare.go.largest", defaultValue: "2 vCPUs, 4 GB")
        case (.largestMachine, .pro):
            L10n.string("mobile.billing.compare.pro.largest", defaultValue: "8 vCPUs, 16 GB")
        case (.largestMachine, .max):
            L10n.string("mobile.billing.compare.max.largest", defaultValue: "32 vCPUs, 64 GB")
        case (.apps, _):
            L10n.string("mobile.billing.compare.included", defaultValue: "Included")
        default:
            nil
        }
    }
}

/// A row of the paywall's plan comparison, from the published pricing facts.
enum BillingComparisonRow: CaseIterable, Hashable {
    case machines
    case sharedCPU
    case sharedMemory
    case largestMachine
    case apps

    var title: String {
        switch self {
        case .machines: L10n.string("mobile.billing.compare.machines", defaultValue: "Cloud VMs")
        case .sharedCPU: L10n.string("mobile.billing.compare.cpu", defaultValue: "Shared vCPUs")
        case .sharedMemory: L10n.string("mobile.billing.compare.memory", defaultValue: "Shared RAM")
        case .largestMachine: L10n.string("mobile.billing.compare.largest", defaultValue: "Largest VM")
        case .apps: L10n.string("mobile.billing.compare.apps", defaultValue: "iPhone and Mac apps")
        }
    }
}
#endif
