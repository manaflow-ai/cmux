/// The user intent attached to an agent launch command.
public enum AgentLaunchIntent: Equatable, Sendable {
    /// Launch an agent without submitting a prompt.
    case launchOnly
    /// Launch an agent when needed, or submit the prompt to an agent that is already running.
    case launchThenSubmitPrompt(String)
}
