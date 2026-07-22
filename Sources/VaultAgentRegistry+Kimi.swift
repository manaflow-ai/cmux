import CMUXAgentLaunch

extension CmuxVaultAgentRegistration {
    static var builtInKimi: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "kimi",
            name: RestorableAgentKind.kimi.displayName,
            detect: CmuxVaultAgentDetectRule(processNames: ["kimi", "kimi-cli", "kimi-code"]),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: "{{executable}} --resume {{sessionId}}",
            cwd: .preserve
        )
    }
}

extension AgentResumeCommandBuilder {
    static func kimiBuiltInResumeArguments(
        customRegistration: CmuxVaultAgentRegistration,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> [String]? {
        guard customRegistration == CmuxVaultAgentRegistration.builtInKimi else { return nil }
        return AgentResumeArgv().builtInKind(
            kind: "kimi",
            sessionId: sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        )
    }
}
