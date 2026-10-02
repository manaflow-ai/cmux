import Foundation

/// One committed change from the owner (`{"event": …}` on the socket).
public nonisolated struct TasksEvent: Sendable {
    public var seq: UInt64
    /// The idempotency key of the request that caused it.
    public var tx: String
    public var kind: String
    public var change: TasksChange
}

public nonisolated enum TasksChange: Sendable {
    case task(TaskItem)
    case status(TaskStatusItem)
    case label(TaskLabelItem)
    case project(TaskProjectItem)
    case session(TaskSessionItem)
    case remove(entity: String, id: String)
    case other
}

public nonisolated enum TasksConnection: Sendable, Equatable {
    case connecting
    case connected
    /// The owner is unreachable: the pane shows it and refuses changes
    /// (nothing queues offline).
    case disconnected(String)
}
