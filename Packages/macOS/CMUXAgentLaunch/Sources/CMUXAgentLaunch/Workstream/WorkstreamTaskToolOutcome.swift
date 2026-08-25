import Foundation

/// The result of applying one task-tool event to a workstream accumulator.
enum WorkstreamTaskToolOutcome: Equatable {
    /// The event did not contain a usable task mutation.
    case ignored
    /// The complete task list after the mutation, including an empty list when
    /// the agent deleted its final task.
    case list([WorkstreamTaskTodo])

    var producedList: Bool {
        if case .list = self { return true }
        return false
    }
}
