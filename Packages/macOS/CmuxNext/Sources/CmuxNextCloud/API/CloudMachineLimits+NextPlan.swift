public import CmuxNextDaemon
import Foundation

extension CloudMachineLimits {
    /// The team's plan as the Cloud app server's `cloud.plan.get` answers it (`CloudPlan`:
    /// `plan_id`, `limits.max_active`, `usage.active`); nil without a plan id. The platform's
    /// `none` (no plan) reads as `free`, so ``paysForCloud`` stays false for it. Sizes are left
    /// out: this answer has no vCPUs for them, and the size picker shows none without both.
    public init?(nextPlan value: JSONValue) {
        guard let plan = value["plan_id"]?.stringValue?.lowercased(), !plan.isEmpty else { return nil }
        let count = { (field: JSONValue?) -> Int? in field?.doubleValue.flatMap { Int(exactly: $0) } }
        self.init(maxActiveVms: count(value["limits"]?["max_active"]), activeVmCount: count(value["usage"]?["active"]) ?? 0,
                  planId: plan == "none" ? "free" : plan)
    }
}
