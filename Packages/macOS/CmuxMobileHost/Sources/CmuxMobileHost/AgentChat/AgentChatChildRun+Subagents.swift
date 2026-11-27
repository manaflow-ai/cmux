public import Foundation

/// Matching a parent's subagent events to its child runs by the agent's own
/// id (Claude's `agent_id`), for agents whose spawn event does not carry it.
///
/// Claude opens a child on its spawn tool's `PreToolUse` and closes it on
/// `SubagentStop`. The spawn names no agent id and the stop names nothing
/// else, but every hook the subagent itself fires carries its id and type, so
/// the first of those binds the id to a child.
extension Array where Element == AgentChatChildRun {
    /// Records that the subagent `agentID` is one of these children.
    ///
    /// Binds the oldest running child with no agent id yet whose spawn asked
    /// for `agentType`, else the oldest whose spawn named no type (or any,
    /// when `agentType` is nil). A child that asked for a different type is
    /// never taken. Does nothing once the id is bound.
    public mutating func bindSubagent(agentID: String, agentType: String?) {
        guard !contains(where: { $0.agentID == agentID }) else { return }
        let unbound = indices.filter { self[$0].endedAt == nil && self[$0].agentID == nil }
        let sameType = agentType.flatMap { type in unbound.first { self[$0].agentType == type } }
        guard let index = sameType ?? unbound.first(where: { self[$0].agentType == nil || agentType == nil }) else {
            return
        }
        self[index].agentID = agentID
    }

    /// Closes the child a subagent stop belongs to.
    ///
    /// A stop that names an agent id closes the child bound to it. If none is
    /// bound (the subagent used no tool), its `agentType` picks the child as
    /// in ``bindSubagent(agentID:agentType:)``. Claude also sends stops for
    /// agent ids that never started, with no type, and repeats a stop for the
    /// same id; those close nothing. A stop with no agent id closes the child
    /// opened under `requestID`, else the oldest running one no agent claimed.
    public mutating func closeSubagent(agentID: String?, agentType: String?, requestID: String?, at date: Date) {
        if let agentID {
            if !contains(where: { $0.agentID == agentID }), agentType != nil {
                bindSubagent(agentID: agentID, agentType: agentType)
            }
            if let index = lastIndex(where: { $0.agentID == agentID }), self[index].endedAt == nil {
                self[index].endedAt = date
            }
            return
        }
        if let requestID, let index = firstIndex(where: { $0.id == requestID && $0.endedAt == nil }) {
            self[index].endedAt = date
            return
        }
        // No correlation on the wire: close the OLDEST open child (FIFO:
        // parallel spawn fan-outs finish roughly in start order more often
        // than not, and a mismatch only swaps two elapsed labels).
        if let index = firstIndex(where: { $0.endedAt == nil && $0.agentID == nil }) {
            self[index].endedAt = date
        }
    }

    /// Closes the running children a task notification names, by agent id
    /// (its `<task-id>`) or by the spawn's tool-use id.
    public mutating func closeSubagents(finishedTaskIDs: some Sequence<String>, at date: Date) {
        let ids = Set(finishedTaskIDs)
        guard !ids.isEmpty else { return }
        for index in indices where self[index].endedAt == nil {
            let child = self[index]
            if child.agentID.map(ids.contains) == true || child.toolUseID.map(ids.contains) == true {
                self[index].endedAt = date
            }
        }
    }
}
