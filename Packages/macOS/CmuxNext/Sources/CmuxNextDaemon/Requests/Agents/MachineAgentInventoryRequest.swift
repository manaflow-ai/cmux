/// Reads cached agent observations only if this daemon owns the selected machine.
///
/// The daemon compares the opaque `machine.list` ID to its own ID before
/// opening acpmux. A stale or reconnected route fails with
/// `agent_inventory.owner_mismatch` without reading the replacement owner's
/// cache. The field is an identity check, never a request to route elsewhere.
///
/// Use the selected connection with a 15-second deadline; propagate failures
/// instead of retrying on a different machine. Older daemons lack the required
/// capability and receive no request. A legacy handshake with no
/// ``DaemonIdentity/machineResourceID`` cannot identify a selectable owner.
///
/// ```swift
/// let request = MachineAgentInventoryRequest(expectedMachineID: machineID)
/// let inventory = try await connection.request(request, timeout: .seconds(15))
/// ```
public nonisolated struct MachineAgentInventoryRequest: DaemonRequest {
    public typealias Response = AcpmuxHarnessInventory
    /// The cache-only native daemon command.
    public static let commandName: DaemonCommandName = "agent-inventory"
    /// Separate negotiation prevents sending the fence to an unfenced legacy owner.
    public static let requiredCapability: String? = "agent-inventory-owner-v1"
    /// The canonical machine ID selected from the catalog, preserved exactly.
    public let expectedMachineID: ResourceID

    /// Creates a cache read bound to the selected machine's public identity.
    /// - Parameter expectedMachineID: The opaque catalog ID, never a hostname or UI route.
    public init(expectedMachineID: ResourceID) {
        self.expectedMachineID = expectedMachineID
    }

    enum CodingKeys: String, CodingKey {
        case expectedMachineID = "expected_machine_id"
    }
}
