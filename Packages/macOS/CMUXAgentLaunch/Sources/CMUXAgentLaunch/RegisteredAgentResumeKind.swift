/// A registry-owned built-in agent whose canonical resume template delegates to ``AgentResumeArgv``.
///
/// The app's built-in Vault registrations use these templates and classify an exact built-in
/// registration before passing its kind to
/// ``AgentResumeArgv/registeredBuiltInKind(kind:sessionId:executablePath:arguments:)``.
public enum RegisteredAgentResumeKind: String, Sendable {
    /// Pi Coding Agent.
    case pi
    /// Oh My Pi.
    case omp
    /// Campfire.
    case campfire
    /// Antigravity.
    case antigravity
    /// Grok CLI.
    case grok
    /// Kimi Code.
    case kimi

    /// The canonical Vault `resumeCommand` template for this built-in agent.
    public var commandTemplate: String {
        switch self {
        case .pi, .omp, .campfire:
            "{{executable}} --session {{sessionId}}"
        case .antigravity:
            "{{executable}} --conversation {{sessionId}}"
        case .grok:
            "{{executable}} -r {{sessionId}}"
        case .kimi:
            "{{executable}} --resume {{sessionId}}"
        }
    }
}
