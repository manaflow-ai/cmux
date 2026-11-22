import Foundation

/// The mirror bootstrap (`{"snapshot": …}` on the socket).
public nonisolated struct TasksSettings: Codable, Sendable, Hashable {
    public var keyPrefix: String

    enum CodingKeys: String, CodingKey {
        case keyPrefix = "key_prefix"
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
