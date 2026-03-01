import Foundation

// MARK: - ScheduledTask

struct ScheduledTask: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var cronExpression: String
    var command: String
    var workingDirectory: String?
    var environment: [String: String]?
    var isEnabled: Bool
    var allowOverlap: Bool
    var useWorktree: Bool?
    var onSuccess: String?
    var onFailure: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        cronExpression: String,
        command: String,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        isEnabled: Bool = true,
        allowOverlap: Bool = false,
        useWorktree: Bool? = nil,
        onSuccess: String? = nil,
        onFailure: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.cronExpression = cronExpression
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.isEnabled = isEnabled
        self.allowOverlap = allowOverlap
        self.useWorktree = useWorktree
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        self.createdAt = createdAt
    }
}

// MARK: - TaskRunStatus

enum TaskRunStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
}

// MARK: - TaskRun

struct TaskRun: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let taskId: UUID
    var panelId: UUID?
    let startedAt: Date
    var completedAt: Date?
    var exitCode: Int32?
    var status: TaskRunStatus

    init(
        id: UUID = UUID(),
        taskId: UUID,
        panelId: UUID? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        exitCode: Int32? = nil,
        status: TaskRunStatus = .running
    ) {
        self.id = id
        self.taskId = taskId
        self.panelId = panelId
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.exitCode = exitCode
        self.status = status
    }
}
