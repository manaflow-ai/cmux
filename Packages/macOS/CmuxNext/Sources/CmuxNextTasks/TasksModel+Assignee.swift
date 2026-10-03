import Foundation

/// The Assignee control (decision T3): one list of people and agents.
extension TasksModel {
    /// The people and agents to offer, from the mirror.
    public var assigneeChoices: TaskAssigneeChoices {
        TaskAssigneeChoices(me: me?.stableID, tasks: visibleTasks, sessions: Array(sessions.values), knownAgents: knownAgents)
    }

    /// Picks `choice` for `task`: a person sends `task.update {assignee}`,
    /// an agent sends `task.delegate`, nobody sends `task.update {unassign}`.
    /// Both go through the intent log with a fresh idempotency key. Returns
    /// false when the task already has that choice or the owner is
    /// unreachable.
    @discardableResult
    public func choose(_ choice: TaskAssigneeChoice, for task: String) -> Bool {
        guard let item = visibleTasks.first(where: { $0.id == task }),
              let intent = choice.intent(for: item, activeSession: activeSession(for: task, harness: choice))
        else { return false }
        return send(intent)
    }

    /// True when `choice` is what the task has now (menu check marks).
    public func isCurrent(_ choice: TaskAssigneeChoice, for task: TaskItem) -> Bool {
        switch choice {
        case let .person(id): task.assignee?.stableID == id
        case .nobody: task.assignee == nil
        case let .agent(harness): task.delegate.map { isMine($0) && $0.harness == harness } ?? false
        }
    }

    private func activeSession(for task: String, harness choice: TaskAssigneeChoice) -> TaskSessionItem? {
        guard case let .agent(harness) = choice else { return nil }
        return sessions.values.first {
            $0.task == task && isMine($0.agent) && $0.agent.harness == harness && !$0.status.isTerminal
        }
    }

    /// The owner keys agents per person (`agt_<harness>-<person>`): only
    /// the local person's agent counts as this choice.
    private func isMine(_ agent: TaskAgent) -> Bool {
        guard let me = me?.stableID else { return true }
        return agent.onBehalfOf == me
    }
}
