/// Which plan limit a Cloud request ran into.
public enum CloudPlanLimit: String, Sendable, CaseIterable {
    case requiresPaidPlan = "requires_paid_plan"
    case activeMachines = "active_machines"
    case machineMemory = "machine_memory"
    case resourcePool = "resource_pool"
    case resizeSize = "resize_size"
    case credits
    case teamBilling = "team_billing"

    /// The limit named by a server error code, or nil when it is not a plan limit.
    public init?(errorCode: String) {
        switch errorCode {
        case "vm_requires_pro": self = .requiresPaidPlan
        case "vm_active_limit_exceeded": self = .activeMachines
        case "vm_memory_requires_plan": self = .machineMemory
        case "vm_resource_pool_exceeded": self = .resourcePool
        case "vm_resize_plan_limit": self = .resizeSize
        case "vm_create_credits_insufficient": self = .credits
        case "vm_billing_team_required", "vm_billing_team_not_found": self = .teamBilling
        default: return nil
        }
    }
}
