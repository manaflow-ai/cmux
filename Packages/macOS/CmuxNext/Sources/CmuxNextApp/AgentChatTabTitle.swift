import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation

/// What an agent chat tab reads as before the user names it: the tab strip and Home's
/// Your agents both show it.
enum AgentChatTabTitle {
    /// The title of the chat `ref` shows, else the name of the workspace it is in
    /// (`workspaceName`: a Chief names each subagent's workspace after its task), else "Agent".
    @MainActor static func untitled(_ ref: AgentSessionRef?, workspaceName: String? = nil,
                                    turns: AgentTurnStateStore = .shared) -> String {
        ref.flatMap(turns.title(for:)) ?? workspaceName.flatMap(taskName) ?? AgentPaneModel.tabTitle
    }

    /// A workspace name as a chat's: without the subagent id an older Chief put in front of its
    /// subagents' workspace names (`String.chiefTaskTitle`); nil when empty.
    static func taskName(_ workspaceName: String) -> String? {
        workspaceName.chiefTaskTitle
    }

    /// The name of `workspace` a chat in it reads as before it has a title: nil for Home, whose
    /// name is the Home workspace's, not a task (a chat beside Home's Chief read "Home", and Home's
    /// Your agents listed two "Home" rows).
    @MainActor static func workspaceName(_ workspace: WorkspaceModel?) -> String? {
        HomeRules.isHome(workspace) ? nil : workspace?.displayName
    }
}
