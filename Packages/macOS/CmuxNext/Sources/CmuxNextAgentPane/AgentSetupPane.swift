import Foundation

/// A chat's Agent setup in a tab of its own (`chat.setupPane`): what the chat's agent is told beside
/// the person's messages, opened from its context card or Session Info. The tab is a new agent pane
/// on the same chat, right of it, whose page shows the setup screen (`_acpmux/agent_setup`, and Save
/// through `_acpmux/agent_setup/save`) instead of the transcript. Leo: "giving the users a better
/// way to ... see what's actually happening ... as a viewer ... I guess you would open up a new tab".
public struct AgentSetupPane {
    public init() {}
    /// The `revealTurn` value that opens a pane on the chat's Agent setup (the page's
    /// `AGENT_SETUP_REVEAL`).
    public static let reveal = "agent-setup"

    /// The name the setup pane's tab shows (``SubagentTabTitles/show(_:inTab:)``).
    public static var title: String {
        String(localized: "agentPane.agentSetup.tabTitle", defaultValue: "Agent setup", bundle: .module)
    }
}
