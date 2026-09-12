import Foundation

/// The app-neutral input used to plan a Vault resume launch.
public struct VaultResumeLaunchRequest: Equatable, Sendable {
    /// Agent-specific values captured by the Vault index.
    public enum AgentProfile: Equatable, Sendable {
        /// Claude Code launch settings.
        case claude(model: String?, permissionMode: String?, configDirectory: String?)
        /// Codex launch settings.
        case codex(model: String?, approvalPolicy: String?, sandboxMode: String?, effort: String?)
        /// Grok launch settings.
        case grok(model: String?, permissionMode: String?, sandboxMode: String?, grokHome: String?)
        /// OpenCode launch settings.
        case opencode(providerModel: String?, agentName: String?)
        /// Rovo Dev's fixed launch shape.
        case rovodev
        /// Hermes launch settings.
        case hermesAgent(source: String?, model: String?, hermesHome: String?)
        /// A registry-owned or user-defined Vault registration.
        case registered(Registration, launchCommand: AgentLaunchCommand? = nil)
    }

    /// The working-directory policy stored on a Vault registration.
    public enum WorkingDirectoryPolicy: String, Equatable, Sendable {
        /// Keep the session's recorded directory when one is available.
        case preserve
        /// Do not attach a directory to the restored process.
        case ignore
    }

    /// The subset of a Vault registration needed for deterministic resume planning.
    public struct Registration: Equatable, Sendable {
        /// Stable registration identifier.
        public let id: String
        /// Executable selected by the registration's detection rule.
        public let defaultExecutable: String
        /// Resume template, including its `{{sessionId}}` placeholder.
        public var resumeCommand: String
        /// Whether the registration uses a cwd for session lookup.
        public let workingDirectoryPolicy: WorkingDirectoryPolicy
        /// Optional session-store directory used by `{{sessionDir}}` templates.
        public let sessionDirectory: String?
        /// Exact built-in resume kind when this registration aliases a built-in provider.
        public let registeredResumeKind: String?

        /// Creates the registration projection consumed by the planner.
        ///
        /// - Parameters:
        ///   - id: Stable registration identifier.
        ///   - defaultExecutable: Executable selected by the registration.
        ///   - resumeCommand: Resume template.
        ///   - workingDirectoryPolicy: Cwd policy stored by Vault.
        ///   - sessionDirectory: Optional template session directory.
        ///   - registeredResumeKind: Built-in kind alias, when applicable.
        public init(
            id: String,
            defaultExecutable: String,
            resumeCommand: String,
            workingDirectoryPolicy: WorkingDirectoryPolicy,
            sessionDirectory: String?,
            registeredResumeKind: String?
        ) {
            self.id = id
            self.defaultExecutable = defaultExecutable
            self.resumeCommand = resumeCommand
            self.workingDirectoryPolicy = workingDirectoryPolicy
            self.sessionDirectory = sessionDirectory
            self.registeredResumeKind = registeredResumeKind
        }
    }

    /// The raw kind used by the `cmux restore` selector.
    public let kind: String
    /// The persisted provider session/checkpoint identifier.
    public let sessionID: String
    /// The directory captured for the Vault entry, if its policy permits one.
    public let workingDirectory: String?
    /// Provider and registration metadata used to build the restore record.
    public let profile: AgentProfile
    /// The rendered command retained solely for the explicit compatibility path.
    public let legacyCommand: String?

    /// Creates a value request without touching app state or the filesystem.
    ///
    /// - Parameters:
    ///   - kind: Raw restore kind.
    ///   - sessionID: Persisted provider session identifier.
    ///   - workingDirectory: Cwd to persist in the restore record.
    ///   - profile: Provider-specific launch metadata.
    ///   - legacyCommand: Existing rendered command used only if structured planning fails.
    public init(
        kind: String,
        sessionID: String,
        workingDirectory: String?,
        profile: AgentProfile,
        legacyCommand: String?
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.profile = profile
        self.legacyCommand = legacyCommand
    }
}
