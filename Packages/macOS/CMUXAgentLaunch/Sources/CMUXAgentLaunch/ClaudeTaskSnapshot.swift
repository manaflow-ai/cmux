/// An authoritative snapshot loaded from one proven Claude task directory.
public struct ClaudeTaskSnapshot: Sendable, Equatable {
    /// The direct child name under Claude's task-store root.
    public let directoryName: String

    /// The complete live task list, including an intentionally empty list.
    public let todos: [WorkstreamTaskTodo]
}
