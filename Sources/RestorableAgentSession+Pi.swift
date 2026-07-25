import CMUXAgentLaunch

extension AgentResumeCommandBuilder {
    static func piBuiltInResumeArguments(
        customRegistration: CmuxVaultAgentRegistration,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> [String]? {
        guard customRegistration.id == CmuxVaultAgentRegistration.builtInPi.id,
              customRegistration.resumeCommand == CmuxVaultAgentRegistration.builtInPi.resumeCommand else {
            return nil
        }
        return AgentResumeArgv().builtInKind(
            kind: "pi",
            sessionId: sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        )
    }
}
