/// A registry-owned built-in agent whose canonical resume template delegates to ``AgentResumeArgv``.
///
/// The app's built-in Vault registrations use these templates, while
/// ``AgentResumeArgv/registeredBuiltInKind(registrationID:resumeCommand:sessionId:executablePath:arguments:)``
/// uses the same declarations to distinguish an unmodified built-in from a user-customized command.
public enum RegisteredAgentResumeKind: String, CaseIterable, Sendable {
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

    /// Resolves an exact canonical built-in registration identity.
    ///
    /// - Parameters:
    ///   - registrationID: The Vault registration identifier.
    ///   - resumeCommand: The registration's current resume-command template.
    ///
    /// Customized templates intentionally do not resolve, leaving the registration's template authoritative.
    public init?(registrationID: String, resumeCommand: String) {
        guard let kind = Self(rawValue: registrationID),
              kind.commandTemplate == resumeCommand else {
            return nil
        }
        self = kind
    }
}
