import Foundation
public import Observation

/// The pane's projection of one team's Tasks owner: a confirmed mirror
/// written only by owner events, plus one ordered intent log. Visible state
/// is mirror + pending intents; an intent leaves on its echo or reject.
@Observable
@MainActor
public final class TasksModel {
    public private(set) var connection: TasksConnection = .connecting
    public private(set) var statuses: [TaskStatusItem] = []
    public private(set) var labels: [String: TaskLabelItem] = [:]
    public private(set) var projects: [String: TaskProjectItem] = [:]
    public private(set) var sessions: [String: TaskSessionItem] = [:]
    public private(set) var me: TaskPrincipal?
    public private(set) var keyPrefix = "CMX"
    public private(set) var seq: UInt64 = 0
    /// Owner-confirmed tasks by id (never written by intents).
    public private(set) var confirmed: [String: TaskItem] = [:]
    /// Pending intents in send order.
    public private(set) var pending: [TasksIntent] = []
    /// The last reject, for a refusal HUD; cleared on the next send.
    public private(set) var lastReject: String?

    /// Client view state (never sent to the owner).
    public var selection: String?
    /// Which tasks the layouts show (client view state; My Tasks sets `.mine`).
    public var scope: TasksScope = .all
    /// Agent harnesses the Assignee control offers (the App may narrow it).
    public var knownAgents: [String] = TaskAssigneeChoices.defaultAgents

    private let source: any TasksSource
    private var statusByID: [String: TaskStatusItem] = [:]
    /// Set when the owner became unreachable while intents were pending;
    /// the next snapshot resends exactly those intents with their keys.
    private var resendAfterReconnect = false

    public init(source: any TasksSource) {
        self.source = source
    }

    public func start() {
        source.start { [weak self] event in self?.handle(event) }
    }

    public func stop() {
        source.stop()
    }

    // MARK: - Visible state

    /// Mirror + pending intents, live tasks only, in manual order.
    public var visibleTasks: [TaskItem] {
        var tasks = confirmed
        for intent in pending {
            intent.apply(to: &tasks, statuses: statusByID, prefix: keyPrefix, me: me?.stableID)
        }
        return tasks.values.filter { !$0.archived && !$0.deleted }.sorted { ($0.sortKey, $0.number) < ($1.sortKey, $1.number) }
    }

    /// The tasks the layouts show: `visibleTasks` narrowed by `scope`.
    public var shownTasks: [TaskItem] {
        let tasks = visibleTasks
        switch scope {
        case .all: return tasks
        case .mine:
            guard let me = me?.stableID else { return [] }
            return tasks.filter { $0.assignee?.stableID == me }
        }
    }

    /// True before the first snapshot: the owner never answered, so the
    /// pane shows how to start it instead of empty layouts.
    public var neverConnected: Bool { me == nil && confirmed.isEmpty && statuses.isEmpty }

    public func status(_ id: String) -> TaskStatusItem? { statusByID[id] }

    /// The task's active agent session, else its most recent one.
    public func session(for task: String) -> TaskSessionItem? {
        let mine = sessions.values.filter { $0.task == task }
        return mine.filter { !$0.status.isTerminal }.min { $0.id < $1.id } ?? mine.max { $0.id < $1.id }
    }

    public func isPending(_ task: String) -> Bool {
        pending.contains { $0.task == task }
    }

    // MARK: - Intents

    /// Send an intent. Refused while the owner is unreachable.
    @discardableResult
    public func send(_ kind: TasksIntentKind) -> Bool {
        guard connection == .connected else {
            lastReject = TasksStrings.disconnected
            return false
        }
        lastReject = nil
        let intent = TasksIntent(kind: kind)
        pending.append(intent)
        source.send(intent)
        return true
    }

    public func setStatus(_ task: String, to status: String) {
        guard visibleTasks.first(where: { $0.id == task })?.status != status else { return }
        send(.setStatus(task: task, status: status))
    }

    /// Reorder `task` to sit between `after` and `before` (visible order).
    public func move(_ task: String, after: String?, before: String?) {
        let tasks = visibleTasks
        let lower = after.flatMap { a in tasks.first { $0.id == a }?.sortKey }
        let upper = before.flatMap { b in tasks.first { $0.id == b }?.sortKey }
        send(.move(task: task, after: after, before: before, sortKey: TasksSortKey.between(lower, upper)))
    }

    // MARK: - Owner events

    func handle(_ event: TasksSourceEvent) {
        switch event {
        case let .connection(state):
            if case .disconnected = state, !pending.isEmpty { resendAfterReconnect = true }
            connection = state
        case let .snapshot(snapshot):
            apply(snapshot)
        case let .event(event):
            apply(event)
        case let .settled(key, reject):
            // Echo events precede the settle line, so the mirror already
            // holds the commit; a no-op commit or a reject settles here.
            pending.removeAll { $0.key == key }
            if let reject { lastReject = reject }
        }
    }

    private func apply(_ snapshot: TasksSnapshot) {
        seq = snapshot.seq
        me = snapshot.me
        keyPrefix = snapshot.settings.keyPrefix
        statuses = snapshot.statuses.sorted { ($0.category.rank, $0.position) < ($1.category.rank, $1.position) }
        statusByID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
        labels = Dictionary(uniqueKeysWithValues: snapshot.labels.map { ($0.id, $0) })
        projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
        sessions = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
        confirmed = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        connection = .connected
        // Reconnect: resend only intents sent before the disconnect, with
        // their keys; the owner's ledger turns a committed one into a replay.
        if resendAfterReconnect {
            resendAfterReconnect = false
            for intent in pending { source.send(intent) }
        }
    }

    private func apply(_ event: TasksEvent) {
        seq = max(seq, event.seq)
        switch event.change {
        case var .task(task):
            task.key = "\(keyPrefix)-\(task.number)"
            task.category = statusByID[task.status]?.category ?? task.category
            confirmed[task.id] = task
        case let .status(status):
            statusByID[status.id] = status
            statuses = statusByID.values.sorted { ($0.category.rank, $0.position) < ($1.category.rank, $1.position) }
        case let .label(label):
            labels[label.id] = label.archived ? nil : label
        case let .project(project):
            projects[project.id] = project.archived ? nil : project
        case let .settings(settings):
            keyPrefix = settings.keyPrefix
        case let .session(session):
            sessions[session.id] = session
        case let .remove(entity, id):
            if entity == "status" {
                statusByID[id] = nil
                statuses.removeAll { $0.id == id }
            }
        case .other:
            break
        }
        // An intent leaves the log at its settle line, which follows every
        // event of its commit, so a multi-event commit never flickers.
    }
}

/// Client-side fractional keys for the move overlay only; the owner
/// computes the committed key (cmux-tasks-core sort_key).
nonisolated enum TasksSortKey {
    static func between(_ a: String?, _ b: String?) -> String {
        switch (a, b) {
        case (nil, nil): return "V"
        case let (a?, nil): return a + "V"
        case let (nil, b?): return b.count > 1 ? String(b.dropLast()) : "0" + b
        case let (a?, b?): return a < b ? a + "V" : a
        }
    }
}
