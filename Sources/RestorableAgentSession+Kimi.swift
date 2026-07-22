import CMUXAgentLaunch

extension AgentResumeCommandBuilder {
    static func kimiBuiltInResumeArguments(
        customRegistration: CmuxVaultAgentRegistration,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> [String]? {
        guard customRegistration.isBuiltInKimi else { return nil }
        return AgentResumeArgv().builtInKind(
            kind: "kimi",
            sessionId: sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        )
    }
}
