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
    public private(set) var settings = TasksSettings(keyPrefix: "CMX")
    public var keyPrefix: String { settings.keyPrefix }
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
    /// Bumped to ask the pane to focus its New Task field (client view
    /// state; the App bumps it only for a user-initiated New Task).
    public internal(set) var newTaskFocusRequest = 0
    /// The last request a New Task field consumed.
    var newTaskFocusHandled = 0
    /// The New Task title typed and not sent (client view state): it outlives the pane's view, so
    /// a page tab whose view was discarded shows it again.
    public var newTaskDraft = ""
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
        let tasks = pending.isEmpty ? Array(confirmed.values) : preview()
        return tasks.filter { !$0.archived && !$0.deleted }.sorted { ($0.sortKey, $0.number) < ($1.sortKey, $1.number) }
    }

    /// The confirmed mirror with the pending intents applied by the owner's
    /// reducer; an intent it would refuse changes nothing.
    private func preview() -> [TaskItem] {
        guard let me else { return Array(confirmed.values) }
        let mirror = TasksPreview.Mirror(seq: seq, me: me, settings: settings, statuses: statuses,
                                         labels: Array(labels.values), projects: Array(projects.values),
                                         tasks: Array(confirmed.values), sessions: Array(sessions.values))
        let intents = pending.map { TasksPreview.Intent(key: $0.key, op: $0.wire.op, params: $0.wire.params) }
        // wall-clock: the preview compares task dates, Unix ms.
        let request = TasksPreview.Request(mirror: mirror, intents: intents, now: Int64(Date().timeIntervalSince1970 * 1000))
        return TasksPreview.run(request)?.tasks ?? Array(confirmed.values)
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

    /// The refusal toast ended: the next refusal shows again.
    public func clearReject() {
        lastReject = nil
    }

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
        send(.move(task: task, after: after, before: before))
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
        settings = snapshot.settings
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
            self.settings = settings
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
