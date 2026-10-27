/// Reads cached agent observations from the machine serving this connection.
///
/// The daemon negotiates the cache-only view with its own running acpmux.
/// A stopped or older owner returns an error; no daemon starts, health checks
/// or updates run. An empty result means no cached observations.
///
/// Call on the selected machine's connection with a 15-second deadline to
/// cover the daemon's two bounded owner calls. Never fall back to another
/// machine when this request fails.
/// For a machine selected by public ID, use ``MachineAgentInventoryRequest``
/// to have the daemon verify ownership before reading its cache.
///
/// ```swift
/// let inventory = try await connection.request(AgentInventoryRequest(), timeout: .seconds(15))
/// ```
public struct AgentInventoryRequest: DaemonRequest {
    public typealias Response = AcpmuxHarnessInventory
    /// The cache-only native daemon command.
    public static let commandName: DaemonCommandName = "agent-inventory"
    /// Older daemons receive no request when they do not advertise this capability.
    public static let requiredCapability: String? = "agent-inventory-v1"

    /// Creates a read of this connection's owner, with no selectors or controls.
    public init() {}
}
