public import Foundation

/// A typed intent the pane sends to the Tasks owner. Until its echo (an
/// event carrying the intent's key as `tx`) or its reject arrives, the pane
/// shows the intent applied on top of the confirmed mirror; no other
/// optimistic copy exists (OWNERSHIP-PRINCIPLES "Clients are projections").
public nonisolated enum TasksIntentKind: Sendable, Equatable {
    case setStatus(task: String, status: String)
    /// Place `task` between `after` (precedes) and `before` (follows).
    case move(task: String, after: String?, before: String?, sortKey: String)
    case create(id: String, title: String, status: String?)
    case archive(task: String)
    /// The accountable person (`task.update {assignee}`); nil unassigns.
    case assign(task: String, person: String?)
    /// Hand the task to an agent (`task.delegate`); `session` is the
    /// client-chosen `asess_` id, so a resend replays the same session.
    case delegate(task: String, session: String, harness: String)
}

public nonisolated struct TasksIntent: Sendable, Equatable, Identifiable {
    /// The idempotency key; the echo carries it as `tx`.
    public let key: String
    public let kind: TasksIntentKind
    public var id: String { key }

    public init(key: String = "idem_" + UUID().uuidString.lowercased(), kind: TasksIntentKind) {
        self.key = key
        self.kind = kind
    }

    /// The catalog op and params (cmux-tasks-core `Op`).
    public var wire: (op: String, params: [String: TasksJSON]) {
        switch kind {
        case let .setStatus(task, status):
            ("task.update", ["task": .string(task), "status": .string(status)])
        case let .move(task, after, before, _):
            ("task.move", ["task": .string(task)]
                .merging(after.map { ["after": .string($0)] } ?? [:]) { a, _ in a }
                .merging(before.map { ["before": .string($0)] } ?? [:]) { a, _ in a })
        case let .create(id, title, status):
            ("task.create", ["id": .string(id), "title": .string(title)]
                .merging(status.map { ["status": .string($0)] } ?? [:]) { a, _ in a })
        case let .archive(task):
            ("task.archive", ["task": .string(task)])
        case let .assign(task, person?):
            ("task.update", ["task": .string(task), "assignee": .string(person)])
        case let .assign(task, nil):
            ("task.update", ["task": .string(task), "unassign": .bool(true)])
        case let .delegate(task, session, harness):
            ("task.delegate", ["task": .string(task), "session": .string(session), "harness": .string(harness)])
        }
    }

    /// The task this intent changes.
    public var task: String {
        switch kind {
        case let .setStatus(task, _), let .move(task, _, _, _), let .archive(task), let .assign(task, _), let .delegate(task, _, _): task
        case let .create(id, _, _): id
        }
    }

    /// The visible effect of this intent on a mirror (pure).
    /// `me` is the local person: a delegation works for them, as the owner
    /// derives it (`agt_<harness>-<person>`).
    func apply(to tasks: inout [String: TaskItem], statuses: [String: TaskStatusItem], prefix: String, me: String? = nil) {
        switch kind {
        case let .setStatus(task, status):
            guard var item = tasks[task], let target = statuses[status] else { return }
            item.status = status
            item.category = target.category
            tasks[task] = item
        case let .move(task, _, _, sortKey):
            tasks[task]?.sortKey = sortKey
        case let .create(id, title, status):
            guard tasks[id] == nil else { return }
            let statusID = status ?? statuses.values.sorted { ($0.category, $0.position) < ($1.category, $1.position) }
                .first { $0.category == .backlog }?.id ?? ""
            let category = statuses[statusID]?.category ?? .backlog
            let last = tasks.values.map(\.sortKey).max() ?? ""
            tasks[id] = TaskItem(id: id, key: "\(prefix)-…", number: 0, title: title, status: statusID,
                                 category: category, sortKey: last + "V")
        case let .archive(task):
            tasks[task]?.archived = true
        case let .assign(task, person):
            tasks[task]?.assignee = person.map { TaskPrincipal(user: $0) }
        case let .delegate(task, _, harness):
            guard var item = tasks[task] else { return }
            let person = me ?? ""
            let name = person.hasPrefix("usr_") ? String(person.dropFirst(4)) : person
            item.delegate = TaskAgent(principal: "agt_\(harness)-\(name)", harness: harness, onBehalfOf: person)
            if item.assignee == nil, !person.isEmpty { item.assignee = TaskPrincipal(user: person) }
            tasks[task] = item
        }
    }
}

/// A small JSON value for intent params and the mock owner.
public nonisolated enum TasksJSON: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case bool(Bool)

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(v): try container.encode(v)
        case let .int(v): try container.encode(v)
        case let .bool(v): try container.encode(v)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else { self = .string(try container.decode(String.self)) }
    }

    public var string: String? {
        if case let .string(v) = self { return v }
        return nil
    }
}
