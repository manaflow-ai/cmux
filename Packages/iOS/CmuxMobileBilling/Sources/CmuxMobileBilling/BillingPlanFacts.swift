import Foundation

/// A plan's compute allowances, as the server's pricing facts state them:
/// the account-token response's optional `planFacts` map, keyed by plan id.
/// The paywall's spec rows and comparison read these; ``builtIn`` is the
/// fallback for a server that sends none. Every field is optional.
public struct BillingPlanFacts: Sendable, Equatable, Hashable, Codable {
    /// Cloud VMs at once.
    public let machines: Int?
    /// vCPUs in the plan's pool (shared by its machines).
    public let vcpus: Int?
    /// RAM in the plan's pool, in GB.
    public let memoryGb: Int?
    /// vCPUs of the largest single machine.
    public let largestVcpus: Int?
    /// RAM of the largest single machine, in GB.
    public let largestMemoryGb: Int?
    /// Included machine hours a month; nil for no hour limit.
    public let vmHoursPerMonth: Int?

    /// Creates facts.
    public init(machines: Int?, vcpus: Int?, memoryGb: Int?, largestVcpus: Int?, largestMemoryGb: Int?, vmHoursPerMonth: Int?) {
        self.machines = machines
        self.vcpus = vcpus
        self.memoryGb = memoryGb
        self.largestVcpus = largestVcpus
        self.largestMemoryGb = largestMemoryGb
        self.vmHoursPerMonth = vmHoursPerMonth
    }

    /// The published facts (cmux.com/pricing) for a server that sends none.
    public static let builtIn: [BillingPlanID: BillingPlanFacts] = [
        .go: BillingPlanFacts(machines: 1, vcpus: 2, memoryGb: 4, largestVcpus: 2, largestMemoryGb: 4, vmHoursPerMonth: 40),
        .pro: BillingPlanFacts(machines: 5, vcpus: 20, memoryGb: 40, largestVcpus: 8, largestMemoryGb: 16, vmHoursPerMonth: nil),
        .max: BillingPlanFacts(machines: 5, vcpus: 80, memoryGb: 160, largestVcpus: 32, largestMemoryGb: 64, vmHoursPerMonth: nil),
    ]
}
