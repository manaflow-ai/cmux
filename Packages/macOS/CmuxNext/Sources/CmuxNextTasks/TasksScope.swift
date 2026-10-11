/// Which tasks the pane lists (client view state, never sent to the owner).
public nonisolated enum TasksScope: String, Sendable, CaseIterable {
    /// Every live task.
    case all
    /// Tasks whose accountable person is the local person (My Tasks).
    case mine
}
