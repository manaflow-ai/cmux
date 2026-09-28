import Foundation

/// Plan meter shown in the panel header: "2 of 3 machines" / "1 of 1 machine".
public struct MachinePlanSnapshot: Equatable, Sendable {
    public init(
        activeCount: Int,
        maxActiveVms: Int? = nil,
        planId: String,
        freeAccessWindowDays: Int = 0,
        freeAccessExpiresAt: Date? = nil,
        freeAccessBanner: FreeAccessBanner = .none
    ) {
        self.activeCount = activeCount
        self.maxActiveVms = maxActiveVms
        self.planId = planId
        self.freeAccessWindowDays = freeAccessWindowDays
        self.freeAccessExpiresAt = freeAccessExpiresAt
        self.freeAccessBanner = freeAccessBanner
    }

    public let activeCount: Int
    /// Active-machine ceiling; nil when the plan has no cap (every paid plan).
    public let maxActiveVms: Int?
    public let planId: String
    /// Days the plan keeps a machine reachable after creation; 0 = no window.
    public var freeAccessWindowDays: Int = 0
    /// Earliest free-access expiry across the fleet (server value when present).
    public var freeAccessExpiresAt: Date? = nil
    public var freeAccessBanner: FreeAccessBanner = .none

    /// An uncapped plan is never at the limit.
    public var isAtLimit: Bool {
        guard let maxActiveVms else { return false }
        return activeCount >= maxActiveVms
    }
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
    public var isSingleMachinePlan: Bool { maxActiveVms == 1 }

    /// The header meter text, singular/plural chosen by the plan's ceiling.
    /// Uncapped plans read "3 machines": there is no "of N" to show.
    public var countLabel: String {
        guard let maxActiveVms else {
            if activeCount == 1 {
                return String(localized: "machines.meter.count.unlimited.single", defaultValue: "1 machine")
            }
            let format = String(localized: "machines.meter.count.unlimited", defaultValue: "%1$d machines")
            return String(format: format, activeCount)
        }
        if isSingleMachinePlan {
            let format = String(localized: "machines.meter.count.single", defaultValue: "%1$d of 1 machine")
            return String(format: format, activeCount)
        }
        let format = String(localized: "machines.meter.count", defaultValue: "%1$d of %2$d machines")
        return String(format: format, activeCount, maxActiveVms)
    }

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
