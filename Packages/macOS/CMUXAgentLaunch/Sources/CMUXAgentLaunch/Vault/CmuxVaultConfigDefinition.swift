public import Foundation

/// The `vault` section of a cmux config file: the list of agent registrations a
/// config contributes to the Vault registry.
///
/// Codable keys match the legacy app type byte-for-byte so persisted config and
/// wire payloads stay compatible.
public struct CmuxVaultConfigDefinition: Codable, Hashable, Sendable {
    /// The agent registrations declared by this config.
    public var agents: [CmuxVaultAgentRegistration]

    /// Creates a config definition.
    public init(agents: [CmuxVaultAgentRegistration] = []) {
        self.agents = agents
    }
}
