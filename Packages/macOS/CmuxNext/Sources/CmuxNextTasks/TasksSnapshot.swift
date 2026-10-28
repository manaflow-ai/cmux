import Foundation

/// The mirror bootstrap (`{"snapshot": …}` on the socket).
public nonisolated struct TasksSettings: Codable, Sendable, Hashable {
    public var keyPrefix: String
    /// The owner's workflow settings, mirrored for the optimistic preview
    /// (cmux-tasks-core `tasks_preview` uses a new team's value when nil).
    public var nextNumber: Int?
    public var defaultStatus: String?
    public var startedStatus: String?
    public var reviewStatus: String?

    enum CodingKeys: String, CodingKey {
        case keyPrefix = "key_prefix"
        case nextNumber = "next_number"
        case defaultStatus = "default_status"
        case startedStatus = "started_status"
        case reviewStatus = "review_status"
    }
}

public nonisolated struct TasksSnapshot: Codable, Sendable {
    public var seq: UInt64
    public var settings: TasksSettings
    public var me: TaskPrincipal
    public var statuses: [TaskStatusItem]
    public var labels: [TaskLabelItem]
    public var projects: [TaskProjectItem]
    public var tasks: [TaskItem]
    public var sessions: [TaskSessionItem]
}

/// A snapshot from the owner that the mirror refuses.
public nonisolated enum TasksSnapshotError: Error, Equatable, Sendable {
    /// Two rows of one entity have the same id. `entity` is the wire name (task, status, label, project, session).
    case duplicateID(entity: String, id: String)
}

nonisolated extension TasksSnapshot {
    /// Throws for two rows of one entity with the same id. The owner keys each table by id, so a
    /// repeated id is corrupt input, not a row to choose.
    public func checkUniqueIDs() throws(TasksSnapshotError) {
        try Self.checkUnique("task", tasks.map(\.id))
        try Self.checkUnique("status", statuses.map(\.id))
        try Self.checkUnique("label", labels.map(\.id))
        try Self.checkUnique("project", projects.map(\.id))
        try Self.checkUnique("session", sessions.map(\.id))
    }

    private static func checkUnique(_ entity: String, _ ids: [String]) throws(TasksSnapshotError) {
        var seen = Set<String>()
        for id in ids where !seen.insert(id).inserted {
            throw .duplicateID(entity: entity, id: id)
        }
    }
}
