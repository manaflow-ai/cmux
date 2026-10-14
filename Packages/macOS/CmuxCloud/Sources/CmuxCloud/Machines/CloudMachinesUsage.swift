import CmuxCloudResizeCore
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
    ///   - resourcePool: The shared vCPU and memory pool, or nil when the plan has none.
    public init(activeCount: Int, maxActiveVms: Int? = nil, isPaidPlan: Bool, resourcePool: CloudVMResourcePool? = nil) {
        self.activeCount = activeCount
        self.maxActiveVms = maxActiveVms
        self.isPaidPlan = isPaidPlan
        self.resourcePool = resourcePool
    }

    /// Number of machines currently counted against the plan.
    public let activeCount: Int
    /// Active-machine ceiling; nil when the plan has no cap (every paid plan).
    public let maxActiveVms: Int?
    /// Whether this usage belongs to a paid plan.
    public let isPaidPlan: Bool
    /// The vCPU and memory pool the active machines share; nil without a pool.
    public let resourcePool: CloudVMResourcePool?

    /// An uncapped plan is never at the limit.
    public var isAtLimit: Bool {
        guard let maxActiveVms else { return false }
        return activeCount >= maxActiveVms
    }

    /// The header tints its count when the plan cannot start another machine:
    /// the machine ceiling is reached, or the pool cannot fit the smallest size.
    public var isWarning: Bool {
        isAtLimit || (resourcePool?.isExhausted ?? false)
    }

    /// The ceiling the header renders as a fraction. A cap of zero or less is
    /// not a quota the count can sit inside: the server closes provisioning
    /// for the plan entirely, so "3/0" reads as arithmetic nonsense while the
    /// fleet it describes is real. Only the fraction drops; `isAtLimit`,
    /// `help` and the upgrade surfaces keep reading the cap itself, so the
    /// paywall is unchanged.
    private var displayedCeiling: Int? {
        guard let maxActiveVms, maxActiveVms > 0 else { return nil }
        return maxActiveVms
    }

    /// Single-machine plans (free) read "1 of 1 machine", never "machines".
    public var isSingleMachinePlan: Bool { maxActiveVms == 1 }

    /// The header's count beside "Cloud Machines": "1/50", or "3" when there is
    /// no ceiling to count against.
    public var compactCount: String {
        guard let maxActiveVms = displayedCeiling else { return String(activeCount) }
        let format = String(localized: "cloudTree.group.cloudMachines.usage", defaultValue: "%1$d/%2$d")
        return String(format: format, activeCount, maxActiveVms)
    }

    /// The spelled-out count, singular/plural chosen by the plan's ceiling.
    /// Plans with no countable ceiling read "3 machines": there is no "of N" to show.
    public var countLabel: String {
        guard let maxActiveVms = displayedCeiling else {
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

    /// Explains the count; at a free plan's ceiling it names the way out. A
    /// plan with a shared pool adds its usage on a second line.
    public var help: String {
        guard let resourcePool else { return countHelp }
        return countHelp + "\n" + resourcePool.usageText
    }

    private var countHelp: String {
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
