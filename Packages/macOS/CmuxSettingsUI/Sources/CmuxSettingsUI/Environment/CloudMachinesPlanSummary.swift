/// Snapshot of the caller's Cloud Machines plan for the settings section.
public struct CloudMachinesPlanSummary: Equatable, Sendable {
    /// Localized display name of the current plan.
    public let planLabel: String
    /// Number of machines currently counted against the plan.
    public let activeMachines: Int
    /// Active-machine ceiling; nil when the plan has no cap.
    public let maxMachines: Int?
    /// Whether the plan permits paid machine provisioning.
    public let isPaidPlan: Bool

    /// Creates a plan summary.
    /// - Parameters:
    ///   - planLabel: Display name of the plan, already localized.
    ///   - activeMachines: Machines currently counted against the plan.
    ///   - maxMachines: Active-machine ceiling, or nil when the plan has no cap.
    ///   - isPaidPlan: Whether the plan is one the backend provisions for.
    public init(planLabel: String, activeMachines: Int, maxMachines: Int?, isPaidPlan: Bool) {
        self.planLabel = planLabel
        self.activeMachines = activeMachines
        self.maxMachines = maxMachines
        self.isPaidPlan = isPaidPlan
    }
}
