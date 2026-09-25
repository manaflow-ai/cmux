import CMUXAgentLaunch

extension CmuxVaultAgentRegistration {
    static var builtInKiro: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "kiro",
            name: RestorableAgentKind.kiro.displayName,
            iconAssetName: "AgentIcons/Kiro",
            detect: CmuxVaultAgentDetectRule(processNames: ["kiro-cli", "kiro"]),
            sessionIdSource: .argvOption("--resume-id"),
            resumeCommand: RegisteredAgentResumeKind.kiro.commandTemplate,
            sessionDirectory: "~/.kiro/sessions/cli"
        )
    }
}
