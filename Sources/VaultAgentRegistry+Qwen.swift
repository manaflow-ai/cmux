import CMUXAgentLaunch

extension CmuxVaultAgentRegistration {
    /// True only for cmux's exact built-in registration, not user registrations reusing its id.
    var isBuiltInQwen: Bool {
        self == Self.builtInQwen
    }

    static var builtInQwen: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "qwen",
            name: RestorableAgentKind.qwen.displayName,
            iconAssetName: "AgentIcons/Qwen",
            detect: CmuxVaultAgentDetectRule(
                processNames: ["qwen", "qwen-code"],
                alternateArgvContains: ["@qwen-code/qwen-code"]
            ),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: RegisteredAgentResumeKind.qwen.commandTemplate,
            cwd: .preserve
        )
    }
}
