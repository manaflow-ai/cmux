import Foundation

/// Active cloud machines against the plan's ceiling, as the Cloud Machines
/// section header shows it. Only the plan facts the count depends on, so the
/// outline rebuilds its header when they change and not on unrelated plan metadata.
public struct CloudMachinesUsage: Equatable, Sendable {
    /// Creates the plan facts displayed by the Cloud Machines header.
    /// - Parameters:
    ///   - activeCount: Number of machines currently counted against the plan.
    ///   - maxActiveVms: Maximum active machines, or nil for an uncapped plan.
    ///   - isPaidPlan: Whether limit help should omit the free-plan upgrade prompt.
    public init(activeCount: Int, maxActiveVms: Int? = nil, isPaidPlan: Bool) {
        self.activeCount = activeCount
        self.maxActiveVms = maxActiveVms
        self.isPaidPlan = isPaidPlan
    }

    /// Number of machines currently counted against the plan.
    public let activeCount: Int
    /// Active-machine ceiling; nil when the plan has no cap (every paid plan).
    public let maxActiveVms: Int?
    /// Whether this usage belongs to a paid plan.
    public let isPaidPlan: Bool

    /// An uncapped plan is never at the limit.
    public var isAtLimit: Bool {
        guard let maxActiveVms else { return false }
        return activeCount >= maxActiveVms
    }

    /// Single-machine plans (free) read "1 of 1 machine", never "machines".
    public var isSingleMachinePlan: Bool { maxActiveVms == 1 }

    /// The header's count beside "Cloud Machines": "1/50", or "3" with no ceiling.
    public var compactCount: String {
        guard let maxActiveVms else { return String(activeCount) }
        let format = String(localized: "cloudTree.group.cloudMachines.usage", defaultValue: "%1$d/%2$d")
        return String(format: format, activeCount, maxActiveVms)
    }

    /// The spelled-out count, singular/plural chosen by the plan's ceiling.
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

    /// Explains the count; at a free plan's ceiling it names the way out.
    public var help: String {
        if isAtLimit && !isPaidPlan, let maxActiveVms {
            if isSingleMachinePlan {
                return String(
                    localized: "machines.meter.help.atLimit.single",
                    defaultValue: "Your plan includes 1 machine. Upgrade to create more."
                )
            }
            // A plural catalog entry: only String(format:) resolves its variant.
            let format = String(
                localized: "machines.meter.help.atLimit",
                defaultValue: "Your plan includes %d machines. Upgrade to create more."
            )
            return String(format: format, maxActiveVms)
        }
        return String(
            localized: "machines.meter.help",
            defaultValue: "Machines on your plan. Sleeping machines cost nothing."
        )
    }
}
