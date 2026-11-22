import Foundation

/// A self-contained owner for demos, snapshots and tests: seeded tasks, and
/// intents applied and echoed on the next main-actor turn (no timers).
@MainActor
public final class MockTasksSource: TasksSource {
    private var sink: (@MainActor (TasksSourceEvent) -> Void)?
    private var snapshot: TasksSnapshot
    private var seq: UInt64
    /// Intents whose key is listed here are rejected (tests).
    public var rejectKeys: Set<String> = []
    /// When false, intents stay pending until `deliverHeld()` (tests).
    public var echoImmediately = true
    private var held: [TasksIntent] = []

    public init(snapshot: TasksSnapshot = MockTasksSource.seed()) {
        self.snapshot = snapshot
        seq = snapshot.seq
    }

    public func start(_ sink: @escaping @MainActor (TasksSourceEvent) -> Void) {
        self.sink = sink
        sink(.connection(.connected))
        sink(.snapshot(snapshot))
    }

    public func stop() {
        sink = nil
    }

    /// Every key the owner received, in order (tests check resends).
    public private(set) var sentKeys: [String] = []
    private var connected = true

    public func send(_ intent: TasksIntent) {
        guard connected else { return }
        sentKeys.append(intent.key)
        if echoImmediately {
            Task { @MainActor [weak self] in self?.commit(intent) }
        } else {
            held.append(intent)
        }
    }

    public func deliverHeld() {
        let intents = held
        held.removeAll()
        for intent in intents { commit(intent) }
    }

    /// Forget held intents (they were lost with the connection).
    public func dropHeld() {
        held.removeAll()
    }

    public func disconnect() {
        connected = false
        held.removeAll()
        sink?(.connection(.disconnected("Tasks owner unreachable")))
    }

    public func reconnect() {
        connected = true
        sink?(.connection(.connected))
        sink?(.snapshot(snapshot))
    }

    /// The mock owner's own rules (not `TasksIntent.apply`, so tests compare
    /// the client's overlay against an independent owner).
    private func commit(_ intent: TasksIntent) {
        guard let sink else { return }
        if committed.contains(intent.key) {
            sink(.settled(key: intent.key, reject: nil))
            return
        }
        if let reject = owner(intent) {
            sink(.settled(key: intent.key, reject: reject))
            return
        }
        committed.insert(intent.key)
        seq += 1
        snapshot.seq = seq
        for task in changed {
            sink(.event(TasksEvent(seq: seq, tx: intent.key, kind: "task.updated", change: .task(task))))
        }
        for session in changedSessions {
            sink(.event(TasksEvent(seq: seq, tx: intent.key, kind: "task.agent_session.created", change: .session(session))))
        }
        changed.removeAll()
        changedSessions.removeAll()
        sink(.settled(key: intent.key, reject: nil))
    }

    private var committed: Set<String> = []
    private var changed: [TaskItem] = []
    private var changedSessions: [TaskSessionItem] = []

    private func index(_ id: String) -> Int? { snapshot.tasks.firstIndex { $0.id == id } }

    /// Applies one intent to the owner state; returns a reject message.
    private func owner(_ intent: TasksIntent) -> String? {
        if rejectKeys.contains(intent.key) { return "rejected by the owner" }
        switch intent.kind {
        case let .setStatus(task, status):
            guard let i = index(task), let target = snapshot.statuses.first(where: { $0.id == status }) else { return "unknown task or status" }
            snapshot.tasks[i].status = status
            snapshot.tasks[i].category = target.category
            changed.append(snapshot.tasks[i])
        case let .move(task, after, before, _):
            var order = snapshot.tasks.filter { !$0.archived }.sorted { $0.sortKey < $1.sortKey }.map(\.id)
            guard order.contains(task) else { return "unknown task" }
            order.removeAll { $0 == task }
            let at = after.flatMap { a in order.firstIndex(of: a).map { $0 + 1 } } ?? before.flatMap { order.firstIndex(of: $0) } ?? order.count
            order.insert(task, at: min(at, order.count))
            for (rank, id) in order.enumerated() {
                guard let i = index(id) else { continue }
                let key = String(format: "%06d", (rank + 1) * 10)
                if snapshot.tasks[i].sortKey != key {
                    snapshot.tasks[i].sortKey = key
                    changed.append(snapshot.tasks[i])
                }
            }
        case let .create(id, title, status):
            guard index(id) == nil else { return "task id already used" }
            let statusID = status ?? "st_backlog"
            guard let target = snapshot.statuses.first(where: { $0.id == statusID }) else { return "unknown status" }
            let number = (snapshot.tasks.map(\.number).max() ?? 0) + 1
            let last = snapshot.tasks.map(\.sortKey).max() ?? ""
            let task = TaskItem(id: id, key: "\(snapshot.settings.keyPrefix)-\(number)", number: number, title: title,
                                status: statusID, category: target.category, sortKey: last + "5")
            snapshot.tasks.append(task)
            changed.append(task)
        case let .archive(task):
            guard let i = index(task) else { return "unknown task" }
            snapshot.tasks[i].archived = true
            changed.append(snapshot.tasks[i])
        case let .assign(task, person):
            guard let i = index(task) else { return "unknown task" }
            if let person, !person.hasPrefix("usr_") { return "assign agents with task.delegate" }
            snapshot.tasks[i].assignee = person.map { TaskPrincipal(user: $0) }
            changed.append(snapshot.tasks[i])
        case let .delegate(task, session, harness):
            return delegate(task: task, session: session, harness: harness)
        }
        return nil
    }
}

extension MockTasksSource {
    /// `task.delegate` as the owner rules it: one active session per agent
    /// and task; the person who delegates becomes the assignee when none.
    private func delegate(task: String, session: String, harness: String) -> String? {
        guard let i = index(task) else { return "unknown task" }
        guard !snapshot.sessions.contains(where: { $0.id == session }) else { return "session id already used" }
        let person = snapshot.me.stableID
        let agent = TaskAgent(principal: "agt_\(harness)-\(snapshot.me.shortName)", harness: harness, onBehalfOf: person)
        if snapshot.sessions.contains(where: { $0.task == task && $0.agent.principal == agent.principal && !$0.status.isTerminal }) {
            return "\(agent.principal) already has an active session on this task"
        }
        let item = TaskSessionItem(id: session, task: task, agent: agent, status: .pending, plan: [])
        snapshot.sessions.append(item)
        snapshot.tasks[i].delegate = agent
        if snapshot.tasks[i].assignee == nil { snapshot.tasks[i].assignee = TaskPrincipal(user: person) }
        changed.append(snapshot.tasks[i])
        changedSessions.append(item)
        return nil
    }

    /// A believable cmux team backlog with agents at work.
    public static func seed() -> TasksSnapshot {
        let statuses = [
            TaskStatusItem(id: "st_triage", name: "Triage", category: .triage, position: 0, color: 13),
            TaskStatusItem(id: "st_backlog", name: "Backlog", category: .backlog, position: 1, color: 8),
            TaskStatusItem(id: "st_todo", name: "Todo", category: .unstarted, position: 2, color: 7),
            TaskStatusItem(id: "st_in_progress", name: "In Progress", category: .started, position: 3, color: 3),
            TaskStatusItem(id: "st_in_review", name: "In Review", category: .started, position: 4, color: 2),
            TaskStatusItem(id: "st_done", name: "Done", category: .completed, position: 5, color: 10),
            TaskStatusItem(id: "st_canceled", name: "Canceled", category: .canceled, position: 6, color: 8),
        ]
        let labels = [
            TaskLabelItem(id: "lbl_bug", name: "bug", color: 1),
            TaskLabelItem(id: "lbl_agent", name: "agent", color: 5),
            TaskLabelItem(id: "lbl_ios", name: "ios", color: 4),
            TaskLabelItem(id: "lbl_perf", name: "perf", color: 3),
        ]
        let category = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0.category) })
        let lawrence = TaskPrincipal(user: "usr_lawrence")
        let austin = TaskPrincipal(user: "usr_austin")
        let claude = TaskAgent(principal: "agt_claude-lawrence", harness: "claude", onBehalfOf: "usr_lawrence")
        let codex = TaskAgent(principal: "agt_codex-lawrence", harness: "codex", onBehalfOf: "usr_lawrence")
        typealias Row = (String, String, TaskPriority, TaskPrincipal?, TaskAgent?, [String], TaskAttention?)
        let rows: [Row] = [
            ("Drag a tab onto a docked column loses the tab", "st_in_progress", .urgent, lawrence, claude, ["lbl_bug", "lbl_agent"], .needsInput),
            ("Tasks: board drag between statuses", "st_in_review", .high, lawrence, codex, ["lbl_agent"], .review),
            ("iOS: reconnect after Wi-Fi handoff", "st_todo", .high, austin, nil, ["lbl_ios"], nil),
            ("Idle wakeups above 1/s with an open browser tab", "st_in_progress", .medium, lawrence, nil, ["lbl_perf"], nil),
            ("Palette: show the task key next to the title", "st_backlog", .low, nil, nil, [], nil),
            ("Agent session plan renders twice after reconnect", "st_triage", .none, nil, nil, ["lbl_bug"], nil),
            ("Team VM: wake latency p95 under 300 ms", "st_todo", .medium, austin, nil, ["lbl_perf"], nil),
            ("Link PRs to tasks by branch name", "st_in_progress", .medium, lawrence, codex, ["lbl_agent"], .failed),
            ("Localize the Tasks pane in Japanese", "st_done", .low, lawrence, nil, [], nil),
            ("Remove the old tracker importer flag", "st_backlog", .none, nil, nil, [], nil),
            ("Status follows agent activity: setting in Settings", "st_todo", .low, lawrence, nil, ["lbl_agent"], nil),
        ]
        var tasks: [TaskItem] = []
        for (index, row) in rows.enumerated() {
            let number = index + 1
            tasks.append(TaskItem(
                id: "task_\(number)", key: "CMX-\(number)", number: number, title: row.0, status: row.1,
                category: category[row.1] ?? .backlog, priority: row.2, assignee: row.3, delegate: row.4,
                labels: row.5, sortKey: String(format: "%02d", number * 3), attention: row.6,
                updatedAt: Int64(1_759_400_000_000 - index * 3_600_000)))
        }
        let sessions = [
            TaskSessionItem(id: "asess_1", task: "task_1", agent: claude, status: .awaitingInput, plan: [
                TaskPlanStep(content: "Reproduce the drop on a docked column", status: "completed"),
                TaskPlanStep(content: "Add a failing reducer test", status: "completed"),
                TaskPlanStep(content: "Fix the drop resolver", status: "in_progress"),
            ]),
            TaskSessionItem(id: "asess_2", task: "task_2", agent: codex, status: .done, plan: [
                TaskPlanStep(content: "Board columns from statuses", status: "completed"),
                TaskPlanStep(content: "Drop sends task.update", status: "completed"),
            ]),
            TaskSessionItem(id: "asess_3", task: "task_8", agent: codex, status: .failed, plan: [
                TaskPlanStep(content: "Parse the key from the branch", status: "completed"),
                TaskPlanStep(content: "GitHub App webhook", status: "pending"),
            ]),
        ]
        return TasksSnapshot(seq: 42, settings: TasksSettings(keyPrefix: "CMX"), me: lawrence, statuses: statuses,
                             labels: labels, projects: [], tasks: tasks, sessions: sessions)
    }
}
