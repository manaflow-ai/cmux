import Foundation

/// The agent-kind information ``AgentResumeCommandBuilder`` needs to assemble a
/// resume/fork command, decoupled from the app-side `RestorableAgentKind` enum.
///
/// The builder keys on three things about the kind: its wire `rawValue` (passed
/// straight to ``AgentResumeArgv/builtInKind(kind:sessionId:executablePath:arguments:)``
/// and the environment-selection policy), whether it is the claude kind (which
/// routes through the wrapper shim and preserves auth-selection env), and whether
/// it is a custom Vault kind (which resolves argv from a registration template).
/// The app forwarder constructs this from `RestorableAgentKind` so the package
/// never imports the app enum.
public struct AgentResumeKindDescriptor: Sendable, Equatable {
    /// The kind's wire identifier (e.g. `"claude"`, `"codex"`, a custom agent id).
    public let rawValue: String

    /// Whether this is the claude kind, which routes its executable through the
    /// `claude` wrapper shim and preserves claude auth-selection environment.
    public let isClaude: Bool

    /// Whether this is a custom Vault agent kind, resolved from a registration
    /// template rather than a built-in resume/fork verb.
    public let isCustom: Bool

    /// Creates a kind descriptor from the kind's wire identifier and its claude
    /// and custom-Vault discriminators.
    public init(rawValue: String, isClaude: Bool, isCustom: Bool) {
        self.rawValue = rawValue
        self.isClaude = isClaude
        self.isCustom = isCustom
    }
}
