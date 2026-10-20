internal import Foundation

final class AnalyticsUploadTaskRegistry: Sendable {
    typealias UploadTask = Task<AnalyticsUploadResult, Never>
    private let state = AnalyticsCriticalState(
        initialValue: (isEnabled: false, tasks: [UUID: UploadTask]())
    )

    func register(_ task: UploadTask, id: UUID) -> Bool {
        state.withCriticalRegion { state in
            guard state.isEnabled else { return false }
            state.tasks[id] = task
            return true
        }
    }

    func remove(id: UUID) {
        _ = state.withCriticalRegion { $0.tasks.removeValue(forKey: id) }
    }

    func setEnabled(_ enabled: Bool) {
        let tasksToCancel: [UploadTask] = state.withCriticalRegion { state in
            state.isEnabled = enabled
            guard !enabled else { return [] }
            let tasks = Array(state.tasks.values)
            state.tasks.removeAll()
            return tasks
        }
        for task in tasksToCancel { task.cancel() }
    }
}
