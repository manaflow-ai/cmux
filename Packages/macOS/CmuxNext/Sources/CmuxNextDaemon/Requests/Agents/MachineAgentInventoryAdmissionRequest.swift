/// Enables an owner watch with explicit proof when a temporary refusal admits no lease.
public nonisolated struct MachineAgentInventoryAdmissionRequest: DaemonRequest {
    /// The same canonical owner/lease/revision receipt as legacy enable.
    public typealias Response = AgentInventoryWatchReceipt
    /// Existing owner watch command; the opt-in field requires its own capability.
    public static let commandName: DaemonCommandName = "agent-inventory-watch"
    /// Guarantees an atomic absence proof on eligible temporary refusals.
    public static let requiredCapability: String? = "agent-inventory-watch-admission-v1"
    /// The currently admitted canonical owner, never a route selector.
    public let expectedMachineID: ResourceID
    /// Only enable may request admission refusal receipts.
    public let enabled = true
    /// Explicit opt-in keeps legacy error shapes unchanged.
    public let admissionReceipt = true

    /// Creates the capability-negotiated enable request.
    /// - Parameter expectedMachineID: The exact owner of the captured ready transport.
    public init(expectedMachineID: ResourceID) { self.expectedMachineID = expectedMachineID }

    enum CodingKeys: String, CodingKey {
        case expectedMachineID = "expected_machine_id", enabled, admissionReceipt = "admission_receipt"
    }
}
