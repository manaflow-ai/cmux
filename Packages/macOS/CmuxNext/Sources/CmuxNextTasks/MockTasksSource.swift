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

    public func send(_ intent: TasksIntent) {
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

    public func disconnect() {
        sink?(.connection(.disconnected("Tasks owner unreachable")))
    }

    private func commit(_ intent: TasksIntent) {
        guard let sink else { return }
        if rejectKeys.contains(intent.key) {
            sink(.settled(key: intent.key, reject: "rejected by the owner"))
            return
        }
        var tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        let statuses = Dictionary(uniqueKeysWithValues: snapshot.statuses.map { ($0.id, $0) })
        intent.apply(to: &tasks, statuses: statuses, prefix: snapshot.settings.keyPrefix)
        seq += 1
        var changed: TaskItem?
        switch intent.kind {
        case let .setStatus(task, _), let .move(task, _, _, _), let .archive(task):
            changed = tasks[task]
        case let .create(id, _, _):
            if !snapshot.tasks.contains(where: { $0.id == id }) {
                let number = (snapshot.tasks.map(\.number).max() ?? 0) + 1
                tasks[id]?.number = number
                tasks[id]?.key = "\(snapshot.settings.keyPrefix)-\(number)"
            }
            changed = tasks[id]
        }
        snapshot.tasks = Array(tasks.values)
        snapshot.seq = seq
        if let changed {
            sink(.event(TasksEvent(seq: seq, tx: intent.key, kind: "task.updated", change: .task(changed))))
        }
        sink(.settled(key: intent.key, reject: nil))
    }
}

extension MockTasksSource {
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
            ("Drag a tab onto a sticky column loses the tab", "st_in_progress", .urgent, lawrence, claude, ["lbl_bug", "lbl_agent"], .needsInput),
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
                TaskPlanStep(content: "Reproduce the drop on a sticky column", status: "completed"),
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
