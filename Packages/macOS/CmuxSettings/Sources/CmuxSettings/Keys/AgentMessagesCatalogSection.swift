import Foundation

/// Settings under the dotted-id prefix `agentMessages.*`.
///
/// ``enabled`` is the app-wide switch for `cmux agent message`: while it is
/// off, sends are refused and queued messages fail instead of being
/// delivered.
public struct AgentMessagesCatalogSection: SettingCatalogSection {
    /// Whether agents can message each other through cmux.
    public let enabled = DefaultsKey<Bool>(
        id: "agentMessages.enabled",
        defaultValue: true,
        userDefaultsKey: "agentMessagesEnabled"
    )

    /// Creates the agent messages settings section with its default keys.
    public init() {}
}
