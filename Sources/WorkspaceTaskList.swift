import Observation

@MainActor
@Observable
final class WorkspaceTaskList {
    var tasks: [WorkspaceTask] = []

    var openTasks: [WorkspaceTask] {
        tasks.filter { $0.isOpen }
    }

    var archivedTasks: [WorkspaceTask] {
        tasks.filter { $0.isArchived }
    }
}
