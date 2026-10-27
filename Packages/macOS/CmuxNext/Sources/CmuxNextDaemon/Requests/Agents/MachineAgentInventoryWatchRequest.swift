/// Enables a cache-only subscription on one existing native owner connection.
///
/// Require the capability and the selected canonical owner identity first.
/// The native daemon negotiates its own acpmux feed; this command never starts
/// a daemon, performs checks or redirects to another owner. Reconnection needs
/// fresh route admission and a new subscription.
public nonisolated struct MachineAgentInventoryWatchRequest: DaemonRequest {
    /// The owner and exact revision accepted for this connection's lease.
    public typealias Response = AgentInventoryWatchReceipt
    /// The internal native subscription command.
    public static let commandName: DaemonCommandName = "agent-inventory-watch"
    /// Require conditional cleanup support before enabling a managed lease.
    public static let requiredCapability: String? = "agent-inventory-watch-fence-v1"
    /// The selected owner's full canonical ID, used only as an identity fence.
    public let expectedMachineID: ResourceID
    /// This request always enables; use the unwatch request to retire a lease.
    public let enabled: Bool

    /// Captures the selected owner without opening or admitting a connection.
    /// - Parameter expectedMachineID: The canonical machine ID from that connection's handshake.
    public init(expectedMachineID: ResourceID) {
        self.expectedMachineID = expectedMachineID
        enabled = true
    }

    enum CodingKeys: String, CodingKey {
        case expectedMachineID = "expected_machine_id", enabled
    }
}
