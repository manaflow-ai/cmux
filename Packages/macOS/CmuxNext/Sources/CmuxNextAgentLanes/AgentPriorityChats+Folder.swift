public import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentPane

extension AgentPriorityChats {
    /// The project folder of the Priority view's chat `id` from its lane (Open in Editor, Copy Path on a row with no
    /// open tab), or why there is none. With `local`, only a chat of this Mac's (or the Chief home's) acpmux, never
    /// a peer's or another machine's. An agent-home folder never leaves the chat (AgentPaneModel.folderForOtherTabs).
    public func folder(of id: String, local: Bool) -> Result<String, AgentChatFolderRefusal> {
        guard let lane = lane(id) else { return .failure(AgentChatFolderRefusal(cause: .noChat)) }
        if local, lane.peer != nil || !stores.contains(where: { $0.lanes[id] != nil }) { return .failure(AgentChatFolderRefusal(cause: .remote)) }
        guard let cwd = lane.cwd, !cwd.isEmpty, AgentHome.standard?.contains(cwd) != true else { return .failure(AgentChatFolderRefusal(cause: .noFolder)) }
        return .success(cwd)
    }
}

/// Why a Priority chat has no folder to open.
public nonisolated struct AgentChatFolderRefusal: Error {
    public var cause: AgentChatRefusal
}
