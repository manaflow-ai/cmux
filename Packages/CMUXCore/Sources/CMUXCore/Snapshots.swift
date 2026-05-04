import Foundation

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let rootPath: String?
    public let activeSessionID: String?
    public let sessionIDs: [String]

    public init(
        id: String,
        name: String,
        rootPath: String?,
        activeSessionID: String?,
        sessionIDs: [String]
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.activeSessionID = activeSessionID
        self.sessionIDs = sessionIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case rootPath = "root_path"
        case activeSessionID = "active_session_id"
        case sessionIDs = "session_ids"
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let workspaceID: String
    public let title: String
    public let currentDirectory: String?
    public let isActive: Bool

    public init(
        id: String,
        workspaceID: String,
        title: String,
        currentDirectory: String?,
        isActive: Bool
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.currentDirectory = currentDirectory
        self.isActive = isActive
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case title
        case currentDirectory = "current_directory"
        case isActive = "is_active"
    }
}
