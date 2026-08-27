import CMUXAgentLaunch

extension CmuxVaultAgentRegistration {
    /// True only for cmux's exact built-in Vibe registration, not user registrations reusing its id.
    var isBuiltInVibe: Bool {
        self == Self.builtInVibe
    }

    /// The built-in Vault registration for Mistral Vibe, using `--resume` for session restore.
    static var builtInVibe: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "vibe",
            name: RestorableAgentKind.vibe.displayName,
            // Do not include "Vibe CLI" here: it is a mutable process title set
            // via setproctitle, not an executable basename. Matching on it would
            // bind an unrelated process to Vibe. Detection relies on the
            // executable-path basename or validated cmux launch metadata.
            detect: CmuxVaultAgentDetectRule(processNames: ["vibe", "mistral-vibe"]),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: RegisteredAgentResumeKind.vibe.commandTemplate,
            cwd: .preserve
        )
    }
}
