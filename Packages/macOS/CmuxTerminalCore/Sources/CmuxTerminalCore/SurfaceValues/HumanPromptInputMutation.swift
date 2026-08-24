/// One human terminal-input event as observed before it reaches the agent.
///
/// Only a possible submit key has useful structure. Every editor operation
/// whose effect depends on agent state remains unknown and therefore
/// fail-closed.
public enum HumanPromptInputMutation: Sendable {
    /// A possible prompt submission, confirmed only by an agent hook.
    case submissionBoundary
    /// An edit whose composer effect cannot be known without screen inference.
    case unknown
}
