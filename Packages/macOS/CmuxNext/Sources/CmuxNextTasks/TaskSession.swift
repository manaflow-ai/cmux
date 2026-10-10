import Foundation

public nonisolated enum TaskSessionStatus: String, Codable, Sendable {
    case pending, claimed, working
    case awaitingInput = "awaiting_input"
    case done, failed, canceled

    public var isTerminal: Bool { self == .done || self == .failed || self == .canceled }
}

public nonisolated struct TaskPlanStep: Codable, Sendable, Hashable {
    public var content: String
    public var status: String
}

public nonisolated struct TaskSessionItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var task: String
    public var agent: TaskAgent
    public var status: TaskSessionStatus
    public var plan: [TaskPlanStep]
}
