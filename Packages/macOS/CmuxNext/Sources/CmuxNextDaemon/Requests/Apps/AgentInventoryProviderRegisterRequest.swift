/// Opts a verified `agent_cli` provider into permissioned inventory demand.
public nonisolated struct AgentInventoryProviderRegisterRequest: DaemonRequest {
    /// The registration's initial demand, ordered with subsequent targeted events.
    public struct Response: Decodable, Sendable {
        /// Families accepted by the native provider registry.
        public let families: [String]
        /// The exact native demand snapshot at registration.
        public let inventoryDemand: AgentInventoryProviderDemand
        enum CodingKeys: String, CodingKey {
            case families
            case inventoryDemand = "inventory_demand"
        }
    }
    /// Existing provider registration command with explicit opt-in.
    public static let commandName: DaemonCommandName = "apps-provider-register"
    /// Native demand and invalidation carrier support.
    public static let requiredCapability: String? = "agent-cli-app-invalidation-v1"
    /// The complete family set, including `agent_cli`.
    public let families: [String]
    /// Explicit opt-in; legacy registration has no extra field.
    public let inventoryWatch = true

    /// Creates the opt-in request; the native owner validates the family set.
    /// - Parameter families: Families implemented by this verified app connection.
    public init(families: [String]) { self.families = families }

    enum CodingKeys: String, CodingKey {
        case families, inventoryWatch = "inventory_watch"
    }
}
