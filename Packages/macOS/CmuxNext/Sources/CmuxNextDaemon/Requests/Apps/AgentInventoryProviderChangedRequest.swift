/// Invalidates readable app inventories without carrying rows or selectors.
public nonisolated struct AgentInventoryProviderChangedRequest: DaemonRequest {
    /// Empty acknowledgement; it is never a job result.
    public typealias Response = EmptyResponse
    /// Strict native invalidation command.
    public static let commandName: DaemonCommandName = "apps-agent-inventory-changed"
    /// Permissioned native invalidation carrier.
    public static let requiredCapability: String? = "agent-cli-app-invalidation-v1"
    /// Exact generation of the still-enabled native demand.
    public let demandSequence: UInt64

    /// Creates an invalidation for one captured enabled demand generation.
    /// - Parameter demandSequence: The latest native demand sequence on this provider.
    public init(demandSequence: UInt64) { self.demandSequence = demandSequence }

    enum CodingKeys: String, CodingKey {
        case demandSequence = "demand_sequence"
    }
}
