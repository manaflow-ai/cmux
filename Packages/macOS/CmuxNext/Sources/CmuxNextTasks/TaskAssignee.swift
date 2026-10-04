import Foundation

/// One entry of the Assignee control (decision T3): people and agents in
/// one list. A person is the accountable `assignee`; an agent becomes the
/// working `delegate` through `task.delegate`, and the owner keeps (or
/// sets) the person it works for as the assignee.
public nonisolated enum TaskAssigneeChoice: Sendable, Hashable, Identifiable {
    /// A person, by `usr_` id.
    case person(String)
    /// An agent harness (`claude`, `codex`, ...), working for the local person.
    case agent(harness: String)
    /// No accountable person.
    case nobody

    public var id: String {
        switch self {
        case let .person(id): "person:\(id)"
        case let .agent(harness): "agent:\(harness)"
        case .nobody: "nobody"
        }
    }

    /// The intent that picks this choice for `task`, or nil when the task
    /// already has it. `newSession` mints the `asess_` id of a delegation.
    public func intent(for task: TaskItem, activeSession: TaskSessionItem?,
                       newSession: () -> String = TaskAssigneeChoice.mintSession) -> TasksIntentKind? {
        switch self {
        case let .person(id):
            guard task.assignee?.stableID != id else { return nil }
            return .assign(task: task.id, person: id)
        case .nobody:
            guard task.assignee != nil else { return nil }
            return .assign(task: task.id, person: nil)
        case let .agent(harness):
            // One working session per agent and task (owner invariant 10).
            if let activeSession, !activeSession.status.isTerminal, activeSession.agent.harness == harness { return nil }
            return .delegate(task: task.id, session: newSession(), harness: harness)
        }
    }

    /// A client-chosen session id the owner accepts (`asess_[0-9a-z_-]{1,64}`).
    public static func mintSession() -> String {
        "asess_" + UUID().uuidString.lowercased()
    }
}

/// The people and agents the Assignee control lists for one task.
public nonisolated struct TaskAssigneeChoices: Sendable, Equatable {
    /// The local person first, then everyone the mirror names, by id.
    public var people: [String]
    /// Agent harnesses: the app's known agents, then any the mirror names.
    public var agents: [String]

    /// Agents cmux launches when the app supplies none.
    public static let defaultAgents = ["claude", "codex", "opencode"]

    /// Collects choices from the mirror. There is no team directory yet, so
    /// people are the local person plus every person a task or delegation
    /// names.
    public init(me: String?, tasks: [TaskItem], sessions: [TaskSessionItem], knownAgents: [String]) {
        var others = Set<String>()
        for task in tasks {
            if let assignee = task.assignee, assignee.kind == "user", let id = assignee.id { others.insert(id) }
            if let delegate = task.delegate { others.insert(delegate.onBehalfOf) }
        }
        for session in sessions { others.insert(session.agent.onBehalfOf) }
        if let me { others.remove(me) }
        others.remove("")
        people = (me.map { [$0] } ?? []) + others.sorted()
        var agents = knownAgents
        let seen = Set(tasks.compactMap(\.delegate?.harness) + sessions.map(\.agent.harness))
        for harness in seen.sorted() where !agents.contains(harness) { agents.append(harness) }
        self.agents = agents
    }

    /// Display name of a harness (product names stay in English).
    public static func agentName(_ harness: String) -> String {
        switch harness {
        case "claude": "Claude"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        case "pi": "Pi"
        default: harness
        }
    }
}
