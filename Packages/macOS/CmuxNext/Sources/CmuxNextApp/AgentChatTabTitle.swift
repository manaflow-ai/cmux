import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
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

    /// A workspace name as a chat's: without the `a345 · ` subagent id a Chief puts in front of
    /// its subagents' workspace names (optchat-chief `workspaces.rs`); nil when empty.
    static func taskName(_ workspaceName: String) -> String? {
        var name = Substring(workspaceName.trimmingCharacters(in: .whitespaces))
        if let dot = name.range(of: " · "), name.first == "a",
           name[name.index(after: name.startIndex)..<dot.lowerBound].allSatisfy(\.isNumber),
           name.distance(from: name.startIndex, to: dot.lowerBound) > 1 {
            name = name[dot.upperBound...]
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
