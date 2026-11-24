/// Tells the GitHub star ask (CmuxNextUpdater's GitHubStarPrompt) that the person sent a prompt in a
/// chat (CmuxNextAgentPane's AgentPaneUserGestures): one subscriber, called directly.
@MainActor public enum PromptSentSignal {
    public static var subscriber: (@MainActor () -> Void)?
    public static func send() { subscriber?() }
}
