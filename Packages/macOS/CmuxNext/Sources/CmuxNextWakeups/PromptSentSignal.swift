/// Tells the GitHub star ask (CmuxNextUpdater's GitHubStarPrompt) that the person sent a prompt in a
/// chat (CmuxNextAgentPane's AgentPaneUserGestures): one subscriber, called directly.
@MainActor public final class PromptSentSignal {
    public static let shared = PromptSentSignal()
    public var subscriber: (@MainActor () -> Void)?
    public func send() { subscriber?() }
}
