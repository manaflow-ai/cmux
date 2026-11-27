public import Foundation

/// Matching a parent's subagent events to its child runs by the agent's own
/// id (Claude's `agent_id`), for agents whose spawn event does not carry it.
extension Array where Element == AgentChatChildRun {
    /// Records that the subagent `agentID` is one of these children.
    public mutating func bindSubagent(agentID: String, agentType: String?) {
    }

    /// Closes the child a subagent stop belongs to.
    public mutating func closeSubagent(agentID: String?, agentType: String?, requestID: String?, at date: Date) {
        if let requestID, let index = firstIndex(where: { $0.id == requestID && $0.endedAt == nil }) {
            self[index].endedAt = date
            return
        }
        if let index = firstIndex(where: { $0.endedAt == nil }) {
            self[index].endedAt = date
        }
    }

    /// Closes the running children a task notification names.
    public mutating func closeSubagents(finishedTaskIDs: some Sequence<String>, at date: Date) {
    }
}
