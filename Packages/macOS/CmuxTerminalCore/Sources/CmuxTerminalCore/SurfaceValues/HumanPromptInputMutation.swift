/// One human terminal-input mutation as observed before it reaches the agent.
///
/// Only simple insertion and backspace preserve exact draft-length knowledge.
/// Every editor operation whose effect depends on agent state remains unknown
/// and therefore fail-closed.
public enum HumanPromptInputMutation: Sendable {
    /// Plain text inserted into a composer whose length may still be known.
    case insert(characterCount: Int)
    /// One unmodified backward-delete event.
    case backspace
    /// A possible prompt submission, confirmed only by an agent hook.
    case submissionBoundary
    /// An edit whose composer effect cannot be known without screen inference.
    case unknown
}
