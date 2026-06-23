import CmuxSettings
import Foundation

extension Workspace {
    static func workspaceTasksBetaEnabled(defaults: UserDefaults = .standard) -> Bool {
        let key = SettingCatalog().betaFeatures.workspaceTasks
        guard defaults.object(forKey: key.userDefaultsKey) != nil else {
            return key.defaultValue
        }
        return defaults.bool(forKey: key.userDefaultsKey)
    }

    var openWorkspaceTasks: [WorkspaceTask] {
        workspaceTasks.filter { $0.isOpen }
    }

    var archivedWorkspaceTasks: [WorkspaceTask] {
        workspaceTasks.filter { $0.isArchived }
    }

    @discardableResult
    func addWorkspaceTask(
        title: String,
        before beforeTaskId: UUID? = nil,
        after afterTaskId: UUID? = nil,
        index requestedIndex: Int? = nil,
        createdAt: Date = Date()
    ) -> WorkspaceTask? {
        let normalizedTitle = WorkspaceTask.normalizedTitle(title)
        guard !normalizedTitle.isEmpty else { return nil }

        var tasks = Self.sanitizedWorkspaceTasks(workspaceTasks)
        let task = WorkspaceTask(title: normalizedTitle, createdAt: createdAt)
        let openCount = tasks.prefix { $0.isOpen }.count
        let insertionIndex: Int
        if let beforeTaskId,
           let beforeIndex = tasks[..<openCount].firstIndex(where: { $0.id == beforeTaskId }) {
            insertionIndex = beforeIndex
        } else if let afterTaskId,
                  let afterIndex = tasks[..<openCount].firstIndex(where: { $0.id == afterTaskId }) {
            insertionIndex = afterIndex + 1
        } else if let requestedIndex {
            insertionIndex = min(max(requestedIndex, 0), openCount)
        } else {
            insertionIndex = openCount
        }
        tasks.insert(task, at: insertionIndex)
        workspaceTasks = tasks
        return task
    }

    @discardableResult
    func archiveWorkspaceTask(id taskId: UUID, archivedAt: Date = Date()) -> WorkspaceTask? {
        var tasks = Self.sanitizedWorkspaceTasks(workspaceTasks)
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        var task = tasks.remove(at: index)
        if task.archivedAt == nil {
            task.archivedAt = archivedAt
        }
        tasks.append(task)
        workspaceTasks = tasks
        return task
    }

    @discardableResult
    func removeWorkspaceTask(id taskId: UUID) -> WorkspaceTask? {
        var tasks = Self.sanitizedWorkspaceTasks(workspaceTasks)
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        let removed = tasks.remove(at: index)
        workspaceTasks = tasks
        return removed
    }

    @discardableResult
    func moveWorkspaceTask(
        id taskId: UUID,
        before beforeTaskId: UUID? = nil,
        after afterTaskId: UUID? = nil,
        index requestedIndex: Int? = nil
    ) -> WorkspaceTask? {
        var tasks = Self.sanitizedWorkspaceTasks(workspaceTasks)
        guard let currentIndex = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        let task = tasks.remove(at: currentIndex)
        let openCount = tasks.prefix { $0.isOpen }.count
        let bucketRange = task.isOpen ? tasks.startIndex..<openCount : openCount..<tasks.endIndex

        let insertionIndex: Int
        if let beforeTaskId {
            guard let beforeIndex = tasks[bucketRange].firstIndex(where: { $0.id == beforeTaskId }) else {
                return nil
            }
            insertionIndex = beforeIndex
        } else if let afterTaskId {
            guard let afterIndex = tasks[bucketRange].firstIndex(where: { $0.id == afterTaskId }) else {
                return nil
            }
            insertionIndex = afterIndex + 1
        } else if let requestedIndex {
            let relativeIndex = min(max(requestedIndex, 0), bucketRange.count)
            insertionIndex = bucketRange.lowerBound + relativeIndex
        } else {
            insertionIndex = min(currentIndex, bucketRange.upperBound)
        }

        tasks.insert(task, at: insertionIndex)
        workspaceTasks = tasks
        return task
    }

    static func sanitizedWorkspaceTasks(_ tasks: [WorkspaceTask]) -> [WorkspaceTask] {
        var seenIds = Set<UUID>()
        var openTasks: [WorkspaceTask] = []
        var archivedTasks: [WorkspaceTask] = []
        openTasks.reserveCapacity(tasks.count)
        archivedTasks.reserveCapacity(tasks.count)

        for task in tasks {
            guard seenIds.insert(task.id).inserted else { continue }
            var sanitizedTask = task
            sanitizedTask.title = WorkspaceTask.normalizedTitle(task.title)
            guard !sanitizedTask.title.isEmpty else { continue }
            if sanitizedTask.isArchived {
                archivedTasks.append(sanitizedTask)
            } else {
                openTasks.append(sanitizedTask)
            }
        }
        return openTasks + archivedTasks
    }
}
