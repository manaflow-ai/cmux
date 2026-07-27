import CMUXAgentLaunch

extension AgentResumeCommandBuilder {
    static func campfireBuiltInResumeArguments(
        customRegistration: CmuxVaultAgentRegistration,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> [String]? {
        guard customRegistration.id == CmuxVaultAgentRegistration.builtInCampfire.id,
              customRegistration.resumeCommand == CmuxVaultAgentRegistration.builtInCampfire.resumeCommand else {
            return nil
        }
        return AgentResumeArgv().builtInKind(
            kind: "campfire",
            sessionId: sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        )
    }
}
