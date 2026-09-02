public import Foundation

/// A Sendable queue row projected from one workspace checklist item.
public struct ControlWorkspaceTaskQueueItem: Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let state: String
    public let workspaceID: UUID
    public let workspaceTitle: String
    public let windowID: UUID?
    public let owningAgent: String?
    public let lastActivityAt: Date?
    public let targetWorkingDirectory: String?
    public let targetAgentCommand: String?
    public let targetAgentName: String?
    public let boundWorkspaceID: UUID?
    public let boundWorkspaceTitle: String?
    public let boundWindowID: UUID?

    public init(
        id: UUID,
        text: String,
        state: String,
        workspaceID: UUID,
        workspaceTitle: String,
        windowID: UUID?,
        owningAgent: String?,
        lastActivityAt: Date?,
        targetWorkingDirectory: String?,
        targetAgentCommand: String?,
        targetAgentName: String?,
        boundWorkspaceID: UUID?,
        boundWorkspaceTitle: String? = nil,
        boundWindowID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.windowID = windowID
        self.owningAgent = owningAgent
        self.lastActivityAt = lastActivityAt
        self.targetWorkingDirectory = targetWorkingDirectory
        self.targetAgentCommand = targetAgentCommand
        self.targetAgentName = targetAgentName
        self.boundWorkspaceID = boundWorkspaceID
        self.boundWorkspaceTitle = boundWorkspaceTitle
        self.boundWindowID = boundWindowID
    }
}
