import Foundation

public nonisolated struct TaskStatusItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var category: TaskCategory
    public var position: Int
    /// Ghostty palette index 0...15.
    public var color: Int
}

public nonisolated struct TaskLabelItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var color: Int
}

public nonisolated struct TaskProjectItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
}
