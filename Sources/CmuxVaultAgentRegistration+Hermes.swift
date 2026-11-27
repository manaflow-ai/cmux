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
                alternateArgvBasenamesAny: ["hermes", "hermes-agent"]
            ),
            sessionIdSource: .persistedStore(.hermesStateDB),
            resumeCommand: "{{executable}} --resume {{sessionId}}",
            cwd: .preserve
        )
    }

    /// The persisted-session semantics supported by this exact cmux-owned registration.
    ///
    /// Keeping this separate from the decoded `sessionIdSource` prevents a custom Vault
    /// registration from claiming the built-in Hermes argument and indexing contract.
    var persistedSessionStoreCapability: CmuxVaultAgentPersistedSessionStore? {
        self == Self.builtInHermes ? .hermesStateDB : nil
    }
}
