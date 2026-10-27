/// Retires this control connection's inventory lease at its captured owner.
///
/// Invalidate local callbacks before sending this command. A stale completion
/// must not disable a new connection's lease or create a replacement connection.
public nonisolated struct MachineAgentInventoryUnwatchRequest: DaemonRequest {
    /// An empty acknowledgement; no owner data is read while disabling.
    public typealias Response = EmptyResponse
    /// The same internal subscription command with enabling disabled.
    public static let commandName: DaemonCommandName = "agent-inventory-watch"
    /// Older owners must never receive an unfenced cleanup fallback.
    public static let requiredCapability: String? = "agent-inventory-watch-fence-v1"
    /// The exact owner of the lease being retired.
    public let expectedMachineID: ResourceID
    /// Conditional retirement: a different current lease remains live.
    public let expectedWatchID: String
    /// This request always disables this connection's own matching lease.
    public let enabled: Bool

    /// Captures the old owner so cleanup cannot redirect to a replacement.
    /// - Parameters:
    ///   - expectedMachineID: The canonical machine ID captured when the lease was admitted.
    ///   - expectedWatchID: The opaque ID returned by that lease's successful receipt.
    public init(expectedMachineID: ResourceID, expectedWatchID: String) {
        self.expectedMachineID = expectedMachineID
        self.expectedWatchID = expectedWatchID
        enabled = false
    }

    enum CodingKeys: String, CodingKey {
        case expectedMachineID = "expected_machine_id", expectedWatchID = "expected_watch_id", enabled
    }
}
