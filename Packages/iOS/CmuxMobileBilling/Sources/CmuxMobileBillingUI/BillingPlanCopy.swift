#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import Foundation

/// Localized name and feature bullets for one cmux plan, matching the web
/// pricing page.
public struct BillingPlanCopy: Equatable {
    /// The plan this copy describes.
    public let planID: BillingPlanID

    /// Creates the copy for `planID`.
    public init(planID: BillingPlanID) {
        self.planID = planID
    }

    /// The localized plan name; an unknown plan shows its capitalized id.
    public var name: String {
        switch planID {
        case .free: L10n.string("mobile.billing.plan.free", defaultValue: "Free")
        case .go: L10n.string("mobile.billing.plan.go", defaultValue: "Go")
        case .pro: L10n.string("mobile.billing.plan.pro", defaultValue: "Pro")
        case .max: L10n.string("mobile.billing.plan.max", defaultValue: "Max")
        default: planID.rawValue.capitalized
        }
    }

    /// The plan's Cloud VM allowances, one line each.
    public var features: [String] {
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
}
#endif
