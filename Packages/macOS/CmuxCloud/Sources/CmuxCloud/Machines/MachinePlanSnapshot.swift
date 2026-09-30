import Foundation

/// The active plan: its machine ceiling, tier and free-access window.
public struct MachinePlanSnapshot: Equatable, Sendable {
    public init(
        activeCount: Int,
        maxActiveVms: Int? = nil,
        planId: String,
        freeAccessWindowDays: Int = 0,
        freeAccessExpiresAt: Date? = nil,
        freeAccessBanner: FreeAccessBanner = .none,
        isCloudAccessGranted: Bool = false
    ) {
        self.activeCount = activeCount
        self.maxActiveVms = maxActiveVms
        self.planId = planId
        self.freeAccessWindowDays = freeAccessWindowDays
        self.freeAccessExpiresAt = freeAccessExpiresAt
        self.freeAccessBanner = freeAccessBanner
        self.isCloudAccessGranted = isCloudAccessGranted
    }

    public let activeCount: Int
    /// Active-machine ceiling; nil when the plan has no cap (every paid plan).
    public let maxActiveVms: Int?
    /// Whether Cloud access is granted outside the plan's machine allowance.
    /// This is decided once from the fleet snapshot, where the machine list is
    /// available to distinguish a granted zero cap from an unentitled one.
    public let isCloudAccessGranted: Bool
    public let planId: String
    /// Days the plan keeps a machine reachable after creation; 0 = no window.
    public var freeAccessWindowDays: Int = 0
    /// Earliest free-access expiry across the fleet (server value when present).
    public var freeAccessExpiresAt: Date? = nil
    public var freeAccessBanner: FreeAccessBanner = .none

    /// The ceiling shown and enforced by the client. A granted zero cap is
    /// inventory-only; an unentitled zero cap remains a paywall ceiling.
    public var meterMaxActiveVms: Int? {
        guard isCloudAccessGranted, (maxActiveVms ?? 1) <= 0 else { return maxActiveVms }
        return nil
    }
    /// Whether the plan has a machine ceiling to display and enforce.
    public var hasPlanMeter: Bool { meterMaxActiveVms != nil }

    /// The count the Cloud Machines header shows, and whether it is at the ceiling.
    public var usage: CloudMachinesUsage {
        CloudMachinesUsage(activeCount: activeCount, maxActiveVms: meterMaxActiveVms, isPaidPlan: isPaidPlan)
    }
    /// An uncapped plan is never at the limit.
    public var isAtLimit: Bool { usage.isAtLimit }
    /// Only plans the backend accepts for provisioning are paid. Unknown plan
    /// ids fail closed here too, so a stale metadata value cannot hide the
    /// upgrade affordance after the server returns `vm_requires_pro`.
    public var isPaidPlan: Bool { Self.isPaidPlanID(planId) }

    public static func isPaidPlanID(_ planId: String) -> Bool {
        switch planId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "go", "pro", "max", "team", "founders":
            return true
        default:
            return false
        }
    }

    /// Single-machine plans (free) read "1 of 1 machine", never "machines".
    public var isSingleMachinePlan: Bool { usage.isSingleMachinePlan }

    /// The banner line under the header; nil when there is nothing to say.
    public var freeAccessBannerText: String? {
        switch freeAccessBanner {
        case .none:
            return nil
        case .expiresIn(let countdown):
            return String(
                format: String(localized: "machines.freeAccess.expiresIn", defaultValue: "Free cloud access \u{00B7} expires in %@"),
                countdown
            )
        case .expiresToday(let countdown):
            return String(
                format: String(localized: "machines.freeAccess.expiresToday", defaultValue: "Free cloud access \u{00B7} expires today, %@ left"),
                countdown
            )
        case .expired:
            return String(localized: "machines.freeAccess.expired", defaultValue: "Free cloud access expired \u{00B7} Upgrade to Pro")
        }
    }
}
