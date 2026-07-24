extension CmuxVaultAgentRegistration {
    static var builtInCampfire: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "campfire",
            name: "Campfire",
            detect: CmuxVaultAgentDetectRule(
                processName: "campfire",
                alternateProcessNames: ["bun", "node", "deno", "tsx", "ts-node"],
                alternateArgvContainsAny: [
                    "packages/session/bin/campfire.ts",
                    "packages/session/dist/campfire",
                ]
            ),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: "~/.campfire/agent/sessions"
        )
    }
}
