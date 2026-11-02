import Foundation

extension CloudMachineLimits {
    /// Whether the plan pays for cmux Cloud: a named plan that is not `free`, and machines are not
    /// closed on it (the same rule as the Mac's create gate). A nil cap is "no cap", which a paid
    /// plan may have; only a zero closes machines.
    public var paysForCloud: Bool {
        guard let plan = planId?.lowercased(), !plan.isEmpty, plan != "free" else { return false }
        return (maxActiveVms ?? 1) > 0
    }
}

extension CloudMachine {
    /// Whether the machine has run at least once: it has a running start, or it is running,
    /// pausing, paused or starting (a paused machine ran before it paused).
    public var hasRun: Bool {
        if runningSince != nil { return true }
        switch status {
        case .running, .pausing, .paused, .starting: return true
        case .provisioning, .failed, .destroyed, .unknown, .deleting: return false
        }
    }

    /// The machine is gone or going: not listed to phones.
    public var isGoneForPhones: Bool {
        status == .destroyed || status == .deleting || shownStatus == .destroyed || shownStatus == .deleting
    }
}
