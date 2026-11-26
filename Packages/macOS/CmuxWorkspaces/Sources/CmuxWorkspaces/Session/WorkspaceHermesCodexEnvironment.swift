/// Injected Hermes Codex environment policy used by workspace session restore.
///
/// The concrete values live in the app target because they come from the agent
/// launch domain; this value keeps `CmuxSession` independent of that package.
public struct WorkspaceHermesCodexEnvironment: Sendable {
    /// Environment key carrying the custom Codex-compatible base URL.
    public let customBaseURLEnvironmentKey: String
    /// Provider name cmux should configure when replaying a Hermes agent binding.
    public let defaultProvider: String
    /// Hermes model API mode for Codex Responses-compatible replay.
    public let codexResponsesAPIMode: String
    private let applyingDefaultCodexBaseURL: @Sendable ([String: String]) -> [String: String]
    private let resolvingDefaultCodexModel: @Sendable ([String: String]) -> String?

    /// Creates a Hermes Codex environment policy.
    public init(
        customBaseURLEnvironmentKey: String,
        defaultProvider: String,
        codexResponsesAPIMode: String,
        applyingDefaultCodexBaseURL: @escaping @Sendable ([String: String]) -> [String: String],
        resolvingDefaultCodexModel: @escaping @Sendable ([String: String]) -> String?
    ) {
        self.customBaseURLEnvironmentKey = customBaseURLEnvironmentKey
        self.defaultProvider = defaultProvider
        self.codexResponsesAPIMode = codexResponsesAPIMode
        self.applyingDefaultCodexBaseURL = applyingDefaultCodexBaseURL
        self.resolvingDefaultCodexModel = resolvingDefaultCodexModel
    }

    /// Returns `environment` with the app's default Codex base URL applied.
    public func applyDefaultCodexBaseURL(to environment: [String: String]) -> [String: String] {
        applyingDefaultCodexBaseURL(environment)
    }

    /// Returns the default Codex model for the supplied environment, if any.
    public func defaultCodexModel(environment: [String: String]) -> String? {
        resolvingDefaultCodexModel(environment)
    }
}
