import Foundation

/// A task tool that can contribute to a workstream checklist.
public enum WorkstreamTaskTool: String, Codable, Sendable, Equatable, CaseIterable {
    /// The legacy whole-list task tool.
    case todoWrite = "TodoWrite"
    /// Claude Code's one-task creation tool.
    case taskCreate = "TaskCreate"
    /// Claude Code's one-task update tool.
    case taskUpdate = "TaskUpdate"
    /// Optional reconciliation read emitted by newer Claude clients.
    case taskGet = "TaskGet"
    /// Optional whole-list reconciliation read emitted by newer Claude clients.
    case taskList = "TaskList"
}
