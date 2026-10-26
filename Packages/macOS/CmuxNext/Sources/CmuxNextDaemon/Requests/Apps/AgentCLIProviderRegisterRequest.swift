/// Registers app families including `agent_cli` only on daemons that know that family.
///
/// Older daemons reject the entire family set when one name is unknown.
/// The separate capability lets the client omit only `agent_cli` before any
/// registration is sent, preserving existing CodeRouter and action owners.
public nonisolated struct AgentCLIProviderRegisterRequest: DaemonRequest {
    /// The daemon's registration result.
    public typealias Response = JSONValue
    /// The existing verified-app registration command.
    public static let commandName: DaemonCommandName = "apps-provider-register"
    /// The daemon knows the agent CLI app-provider family.
    public static let requiredCapability: String? = "agent-cli-app-provider-v1"
    /// Families this verified app connection serves.
    public let families: [String]

    /// Creates a capability-gated provider registration.
    /// - Parameter families: The app's complete family set, including `agent_cli`.
    public init(families: [String]) { self.families = families }
}
