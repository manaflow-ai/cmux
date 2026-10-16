import CMUXAgentLaunch
import Foundation

extension CmuxVaultAgentRegistration {
    /// Amp's built-in Vault registration backed by cmux's managed hook store.
    static var builtInAmp: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "amp",
            name: "Amp",
            iconAssetName: "AgentIcons/Amp",
            detect: CmuxVaultAgentDetectRule(processName: "amp"),
            sessionIdSource: .cmuxHookStore(.amp),
            resumeCommand: RegisteredAgentResumeKind.amp.commandTemplate,
            cwd: .preserve
        )
    }
}
