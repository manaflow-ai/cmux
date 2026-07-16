extension CmuxVaultAgentRegistration {
    static var builtInCodePuppy: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "code-puppy",
            name: "Code Puppy",
            iconAssetName: "AgentIcons/CodePuppy",
            detect: CmuxVaultAgentDetectRule(
                processNames: ["code-puppy", "code_puppy"],
                alternateArgvContains: ["code_puppy"]
            ),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: "{{executable}} --resume {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: "~/.code_puppy/autosaves"
        )
    }
}
