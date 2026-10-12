import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon

/// What an agent chat tab reads as before the user names it: the tab strip and Home's
/// Your agents both show it.
enum AgentChatTabTitle {
    /// The title of the chat `ref` shows, else "Agent".
    @MainActor static func untitled(_ ref: AgentSessionRef?, turns: AgentTurnStateStore = .shared) -> String {
        ref.flatMap(turns.title(for:)) ?? AgentPaneModel.tabTitle
    }
}
