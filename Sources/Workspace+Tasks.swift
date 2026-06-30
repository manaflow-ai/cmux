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
        workspaceTaskList.openTasks
    }

    var archivedWorkspaceTasks: [WorkspaceTask] {
        workspaceTaskList.archivedTasks
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
        guard !normalizedTitle.isEmpty,
              normalizedTitle.count <= WorkspaceTask.maximumTitleCharacters
        else { return nil }

        var tasks = Self.sanitizedWorkspaceTasks(workspaceTasks)
        let task = WorkspaceTask(title: normalizedTitle, createdAt: createdAt)
        let openCount = tasks.prefix { $0.isOpen }.count
        guard openCount < WorkspaceTask.maximumOpenTaskCount else { return nil }
        let insertionIndex: Int
        if let beforeTaskId {
            guard let beforeIndex = tasks[..<openCount].firstIndex(where: { $0.id == beforeTaskId }) else {
                return nil
            }
            insertionIndex = beforeIndex
        } else if let afterTaskId {
            guard let afterIndex = tasks[..<openCount].firstIndex(where: { $0.id == afterTaskId }) else {
                return nil
            }
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
        let openCount = tasks.prefix { $0.isOpen }.count
        let archivedCount = tasks.count - openCount
        guard !tasks[index].isOpen || archivedCount < WorkspaceTask.maximumArchivedTaskCount else {
            return nil
        }
        var task = tasks.remove(at: index)
        if task.archivedAt == nil {
            task.archivedAt = archivedAt
        }
        tasks.append(task)
        workspaceTasks = tasks
        return task
    }

    @discardableResult
    func unarchiveWorkspaceTask(id taskId: UUID) -> WorkspaceTask? {
        var tasks = Self.sanitizedWorkspaceTasks(workspaceTasks)
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        guard tasks[index].isArchived else { return tasks[index] }
        let openCount = tasks.prefix { $0.isOpen }.count
        guard openCount < WorkspaceTask.maximumOpenTaskCount else { return nil }
        var task = tasks.remove(at: index)
        task.archivedAt = nil
        tasks.insert(task, at: openCount)
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
            return nil
        }

        tasks.insert(task, at: insertionIndex)
        workspaceTasks = tasks
        return task
    }

    static func sanitizedWorkspaceTasks(_ tasks: [WorkspaceTask]) -> [WorkspaceTask] {
        var seenIds = Set<UUID>()
        var openTasks: [WorkspaceTask] = []
        var archivedTasks: [WorkspaceTask] = []
        openTasks.reserveCapacity(min(tasks.count, WorkspaceTask.maximumOpenTaskCount))
        archivedTasks.reserveCapacity(min(tasks.count, WorkspaceTask.maximumArchivedTaskCount))

        for task in tasks {
            guard openTasks.count < WorkspaceTask.maximumOpenTaskCount
                    || archivedTasks.count < WorkspaceTask.maximumArchivedTaskCount else {
                break
            }
            guard seenIds.insert(task.id).inserted else { continue }
            var sanitizedTask = task
            sanitizedTask.title = WorkspaceTask.boundedTitle(task.title)
            guard !sanitizedTask.title.isEmpty else { continue }
            if sanitizedTask.isArchived {
                if archivedTasks.count < WorkspaceTask.maximumArchivedTaskCount {
                    archivedTasks.append(sanitizedTask)
                }
            } else {
                if openTasks.count < WorkspaceTask.maximumOpenTaskCount {
                    openTasks.append(sanitizedTask)
                }
            }
        }
        return openTasks + archivedTasks
    }
}
