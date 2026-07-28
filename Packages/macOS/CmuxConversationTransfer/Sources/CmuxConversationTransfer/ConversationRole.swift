/// A harness-neutral role for one normalized conversation turn.
public enum ConversationRole: Equatable, Sendable {
    /// A request or follow-up supplied by the user.
    case user
    /// A response supplied by the agent.
    case assistant
    /// System or developer context recorded by the source harness.
    case system
    /// A tool invocation or tool result.
    case tool
    /// Provider metadata that is not part of the user-agent dialogue.
    case event
}
