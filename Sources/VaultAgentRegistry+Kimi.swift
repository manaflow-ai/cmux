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
