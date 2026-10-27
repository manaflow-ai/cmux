/// Refreshes registry releases for cached installations on one selected owner.
///
/// The owner checks its canonical identity before connecting to acpmux. The
/// operation never probes CLIs, reads sign-ins, starts an owner or installs
/// anything. Older owners receive no request. Use the captured connection
/// with a 28-second deadline and validate the receipt's machine before use.
public nonisolated struct MachineAgentInventoryRefreshRequest: DaemonRequest {
    public typealias Response = AgentInventoryRefreshReceipt
    /// The registry-only native carrier command.
    public static let commandName: DaemonCommandName = "agent-inventory-refresh"
    /// Negotiates the registry-only operation and its required owner fence.
    public static let requiredCapability: String? = "agent-inventory-refresh-v1"
    /// The exact public machine ID selected from the admitted catalog.
    public let expectedMachineID: ResourceID

    /// Creates a registry refresh bound to one machine's public identity.
    /// - Parameter expectedMachineID: The opaque catalog ID, never a routing alias.
    public init(expectedMachineID: ResourceID) {
        self.expectedMachineID = expectedMachineID
    }

    enum CodingKeys: String, CodingKey {
        case expectedMachineID = "expected_machine_id"
    }
}
