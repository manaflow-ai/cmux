import Foundation

/// The custom Vault-agent registration fields ``AgentResumeCommandBuilder``
/// needs to resolve a custom agent's resume/fork argv, decoupled from the
/// app-side `CmuxVaultAgentRegistration` Codable struct.
///
/// A custom agent resolves its argv from `resumeCommand`/`forkCommand` mustache
/// templates, falls back to `defaultExecutable`, expands `sessionDirectory` into
/// the `{{sessionDir}}` replacement, applies its `cwd` policy to the cd-guard,
/// and the antigravity built-in takes a `--conversation` resume path keyed by
/// `isAntigravity`. The app forwarder maps a `CmuxVaultAgentRegistration` onto
/// this value so the package does not duplicate the registry type.
public struct AgentResumeRegistrationOverride: Sendable, Equatable {
    /// How the resumed command treats the captured working directory.
    public enum CwdPolicy: Sendable, Equatable {
        /// Resume from the captured working directory (the cd-guard is emitted).
        case preserve
        /// Resume from the current directory (no cd-guard prefix).
        case ignore
    }

    /// The agent's resume-command mustache template.
    public let resumeCommand: String

    /// The agent's fork-command mustache template, or `nil` when the agent has
    /// no fork capability.
    public let forkCommand: String?

    /// The agent's working-directory policy for the resumed command.
    public let cwd: CwdPolicy

    /// The agent's session-id store directory, expanded into `{{sessionDir}}`.
    public let sessionDirectory: String?

    /// The executable used when the captured launch command has none.
    public let defaultExecutable: String

    /// Whether this registration is the built-in antigravity agent, which
    /// resumes via `--conversation <id>` rather than its template.
    public let isAntigravity: Bool

    /// Creates a registration override from the fields the resume builder reads.
    public init(
        resumeCommand: String,
        forkCommand: String?,
        cwd: CwdPolicy,
        sessionDirectory: String?,
        defaultExecutable: String,
        isAntigravity: Bool
    ) {
        self.resumeCommand = resumeCommand
        self.forkCommand = forkCommand
        self.cwd = cwd
        self.sessionDirectory = sessionDirectory
        self.defaultExecutable = defaultExecutable
        self.isAntigravity = isAntigravity
    }
}
