import CMUXAgentLaunch
import Foundation

extension CmuxVaultAgentRegistration {
    static var builtInHermes: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "hermes-agent",
            name: String(
                localized: "sessionIndex.agent.hermesAgent",
                defaultValue: "Hermes Agent"
            ),
            iconAssetName: "AgentIcons/HermesAgent",
            detect: CmuxVaultAgentDetectRule(
                processNames: ["hermes", "hermes-agent"],
                alternateProcessNames: ["python", "python3"],
                alternateArgvContainsAny: ["hermes-agent/hermes"]
            ),
            sessionIdSource: .persistedStore(.hermesStateDB),
            resumeCommand: "{{executable}} --resume {{sessionId}}",
            cwd: .preserve
        )
    }

    /// The persisted-store source this exact cmux-owned registration may access.
    ///
    /// Keeping this separate from the decoded `sessionIdSource` prevents arbitrary custom Vault
    /// registrations from pointing the scanner at a user's Hermes database.
    var persistedSessionStoreCapability: CmuxVaultAgentPersistedSessionStore? {
        self == Self.builtInHermes ? .hermesStateDB : nil
    }
}
