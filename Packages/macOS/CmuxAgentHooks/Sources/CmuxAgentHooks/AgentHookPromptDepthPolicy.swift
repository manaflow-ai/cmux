/// Describes whether prompt-start callbacks represent balanced frames or one authoritative loop.
public enum AgentHookPromptDepthPolicy: Sendable, Equatable {
    /// Each prompt-start callback opens a frame that a later completion closes individually.
    case balanced

    /// Repeated prompt-start callbacks describe one active loop closed by its completion boundary.
    case authoritative

    /// Whether a completion boundary closes every active prompt frame.
    public var closesActivePrompt: Bool {
        switch self {
        case .balanced:
            false
        case .authoritative:
            true
        }
    }
}
