import CMUXAgentLaunch

extension CmuxVaultAgentRegistration {
    /// True only for cmux's exact built-in registration, not user registrations reusing its id.
    var isBuiltInVibe: Bool {
        self == Self.builtInVibe
    }

    static var builtInVibe: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "vibe",
            name: RestorableAgentKind.vibe.displayName,
            detect: CmuxVaultAgentDetectRule(processNames: ["vibe", "Vibe CLI", "mistral-vibe"]),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: RegisteredAgentResumeKind.vibe.commandTemplate,
            cwd: .preserve
        )
    }
}
