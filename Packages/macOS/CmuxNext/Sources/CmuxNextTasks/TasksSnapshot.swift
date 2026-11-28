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
