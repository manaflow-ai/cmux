/// The shared Code Puppy integration contract used by cmux launch, hook, and resume surfaces.
///
/// The executable targets keep their own app-specific wiring types, while this
/// value keeps the agent's stable names, paths, and protocol details in the
/// package that can be tested independently.
public struct CodePuppyAgentRegistration: Equatable, Sendable {
    /// The stable cmux agent identifier.
    public let id: String
    /// The command cmux launches for a new session.
    public let commandName: String
    /// The asset catalog name for the agent icon.
    public let iconAssetName: String
    /// The fallback SF Symbol name for the agent icon.
    public let defaultSymbolName: String
    /// Launch-kind values that identify the agent.
    public let launchKinds: [String]
    /// Executable basenames that identify the agent directly.
    public let directBasenames: [String]
    /// Argument tokens that identify wrapped or module-based launches.
    public let argumentNeedles: [String]
    /// Config values accepted as the agent kind in cmux settings.
    public let configAliases: [String]
    /// Aliases accepted by the generic hook CLI.
    public let hookAliases: [String]
    /// The directory under the user's home directory containing hook config.
    public let hookConfigDirectory: String
    /// The hook configuration file name.
    public let hookConfigFile: String
    /// The executable used to check whether hooks can be installed.
    public let binaryName: String
    /// The suffix used for cmux's hook-session store.
    public let sessionStoreSuffix: String
    /// The environment variable that disables installed hooks.
    public let disableHooksEnvironmentVariable: String
    /// The environment variable used to associate hook events with the agent process.
    public let pidEnvironmentVariable: String
    /// The marker embedded in generated hook commands.
    public let hookMarker: String
    /// The Code Puppy hook timeout, in milliseconds.
    public let hookTimeoutMilliseconds: Int
    /// The matcher required on every nested Code Puppy hook group.
    public let nestedGroupMatcher: String
    /// A lifecycle hook event and its cmux subcommand.
    public struct HookEvent: Equatable, Sendable {
        /// The event name emitted by Code Puppy.
        public let agentEvent: String
        /// The cmux hook subcommand invoked for the event.
        public let cmuxSubcommand: String

        /// Creates a Code Puppy lifecycle hook event mapping.
        /// - Parameters:
        ///   - agentEvent: The event name emitted by Code Puppy.
        ///   - cmuxSubcommand: The cmux hook subcommand invoked for the event.
        public init(agentEvent: String, cmuxSubcommand: String) {
            self.agentEvent = agentEvent
            self.cmuxSubcommand = cmuxSubcommand
        }
    }

    /// Lifecycle events wired to cmux hook subcommands.
    public let lifecycleEvents: [HookEvent]
    /// Tool events wired to the cmux Feed bridge.
    public let feedEvents: [String]
    /// The native resume option accepted by Code Puppy.
    public let resumeOption: String
    /// The resume command template used by cmux.
    public let resumeCommand: String
    /// The directory containing Code Puppy's persisted sessions.
    public let sessionDirectory: String
    /// Argument tokens used by the Vault detector for wrapped launches.
    public let vaultAlternateArgvContains: [String]

    /// Creates the canonical Code Puppy integration contract.
    public init() {
        id = "code-puppy"
        commandName = "code-puppy"
        iconAssetName = "AgentIcons/CodePuppy"
        defaultSymbolName = "pawprint"
        launchKinds = ["code-puppy"]
        directBasenames = ["code-puppy", "code_puppy"]
        argumentNeedles = ["code-puppy", "code_puppy"]
        configAliases = ["code-puppy", "codePuppy", "code_puppy", "codepuppy", "pup"]
        hookAliases = ["pup"]
        hookConfigDirectory = ".code_puppy"
        hookConfigFile = "hooks.json"
        binaryName = "code-puppy"
        sessionStoreSuffix = "code-puppy"
        disableHooksEnvironmentVariable = "CMUX_CODE_PUPPY_HOOKS_DISABLED"
        pidEnvironmentVariable = "CMUX_CODE_PUPPY_PID"
        hookMarker = "cmux hooks code-puppy"
        hookTimeoutMilliseconds = 5_000
        nestedGroupMatcher = "*"
        lifecycleEvents = [
            HookEvent(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
            HookEvent(agentEvent: "UserPromptSubmit", cmuxSubcommand: "prompt-submit"),
            HookEvent(agentEvent: "Stop", cmuxSubcommand: "stop"),
            HookEvent(agentEvent: "Notification", cmuxSubcommand: "notification"),
            HookEvent(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
        ]
        feedEvents = ["PreToolUse", "PostToolUse"]
        resumeOption = "--resume"
        resumeCommand = "{{executable}} --resume {{sessionId}}"
        sessionDirectory = "~/.code_puppy/autosaves"
        vaultAlternateArgvContains = ["code_puppy"]
    }

    /// The canonical contract for the built-in Code Puppy integration.
    public static let standard = CodePuppyAgentRegistration()
}
