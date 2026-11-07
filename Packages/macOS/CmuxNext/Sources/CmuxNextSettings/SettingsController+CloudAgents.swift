import Foundation

/// The person's delegation of agents' Cloud use (``CloudAgentStartSetting``) as the app reads and writes it.
extension SettingsController {
    /// Whether agents, the CLI and scripts create, move and start on Cloud without asking (on by default).
    public var cloudAgentsSkipAsking: Bool { CloudAgentStartSetting().delegated(in: snapshot.root) }

    /// The create card's Don't Ask Again: the person's own click turns asking off again, or nil (no switch)
    /// while a managed preference (docs/mdm) sets the key.
    public var stopAskingCloudAgents: (@MainActor () async -> Void)? {
        guard managedKeys[CloudAgentStartSetting.key] == nil else { return nil }
        return { [weak self] in try? await self?.setSetting(at: CloudAgentStartSetting.path, to: .bool(true), by: .user) }
    }
}
