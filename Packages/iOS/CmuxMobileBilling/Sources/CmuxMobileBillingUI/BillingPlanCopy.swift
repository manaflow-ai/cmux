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
                L10n.string("mobile.billing.plan.pro.size", defaultValue: "Sharing 20 vCPUs and 40 GB RAM"),
            ]
        case .max:
            [
                L10n.string("mobile.billing.plan.max.machines", defaultValue: "Up to 5 Cloud VMs"),
                L10n.string("mobile.billing.plan.max.size", defaultValue: "Sharing 80 vCPUs and 160 GB RAM"),
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
