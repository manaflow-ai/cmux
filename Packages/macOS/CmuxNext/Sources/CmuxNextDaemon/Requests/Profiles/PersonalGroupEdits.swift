import Foundation

public struct DeletePersonalGroupRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "delete-personal-group"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public var group: WorkspaceGroupID
    public init(group: WorkspaceGroupID) { self.group = group }
}

public struct MovePersonalGroupRequest: DaemonRequest {
    public typealias Response = PersonalGroupResult
    public static let command = "move-personal-group"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public var group: WorkspaceGroupID
    public var index: Int
    public init(group: WorkspaceGroupID, index: Int) {
        self.group = group
        self.index = index
    }
}

/// Sets a qualified workspace's personal order (insertion index), group,
/// browser profile or theme; JSON null clears.
public struct SetPersonalWorkspaceRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-personal-workspace"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public var sessionID: String
    public var workspaceKey: WorkspaceKey
    public var index: Int?
    public var group: FieldUpdate<WorkspaceGroupID>
    public var browserProfileID: FieldUpdate<BrowserProfileKey>
    public var theme: FieldUpdate<String>
    public init(sessionID: String, workspaceKey: WorkspaceKey, index: Int? = nil, group: FieldUpdate<WorkspaceGroupID> = .unchanged,
                browserProfileID: FieldUpdate<BrowserProfileKey> = .unchanged, theme: FieldUpdate<String> = .unchanged) {
        self.sessionID = sessionID
        self.workspaceKey = workspaceKey
        self.index = index
        self.group = group
        self.browserProfileID = browserProfileID
        self.theme = theme
    }

    enum CodingKeys: String, CodingKey {
        case index, group, theme
        case sessionID = "session_id"
        case workspaceKey = "workspace_key"
        case browserProfileID = "browser_profile_id"
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(workspaceKey, forKey: .workspaceKey)
        try c.encodeIfPresent(index, forKey: .index)
        try c.encode(group, forKey: .group)
        try c.encode(browserProfileID, forKey: .browserProfileID)
        try c.encode(theme, forKey: .theme)
    }
}
