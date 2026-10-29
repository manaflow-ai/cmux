import CMUXAgentLaunch

extension CmuxVaultAgentRegistration {
    /// True only for cmux's exact built-in registration, not user registrations reusing its id.
    var isBuiltInMuse: Bool {
        self == Self.builtInMuse
    }

    /// Muse Code's built-in Vault registration, listed from Muse's own `session-index.db`.
    static var builtInMuse: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "muse",
            name: RestorableAgentKind.muse.displayName,
            detect: CmuxVaultAgentDetectRule(processNames: ["muse"]),
            sessionIdSource: .argvOption("resume"),
            resumeCommand: RegisteredAgentResumeKind.muse.commandTemplate,
            cwd: .preserve,
            sessionDirectory: "~/.local/share/muse"
        )
    }
}
