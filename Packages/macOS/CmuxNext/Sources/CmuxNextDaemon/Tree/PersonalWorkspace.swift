import Foundation

/// A workspace pinned to one room.
public struct WorkspacePin: Sendable, Hashable, Codable {
    public var sessionID: String
    public var workspaceKey: WorkspaceKey
    public var profile: ProfileID

    public init(sessionID: String, workspaceKey: WorkspaceKey, profile: ProfileID) {
        self.sessionID = sessionID
        self.workspaceKey = workspaceKey
        self.profile = profile
    }

    enum CodingKeys: String, CodingKey {
        case profile
        case sessionID = "session_id"
        case workspaceKey = "workspace_key"
    }
}

/// Personal organization of one qualified workspace.
public struct PersonalWorkspace: Sendable, Hashable, Decodable {
    public var sessionID: String
    public var workspaceKey: WorkspaceKey
    public var index: Int
    public var group: WorkspaceGroupID?
    public var browserProfileID: BrowserProfileKey?
    public var theme: String?

    public init(sessionID: String, workspaceKey: WorkspaceKey, index: Int, group: WorkspaceGroupID? = nil,
                browserProfileID: BrowserProfileKey? = nil, theme: String? = nil) {
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

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        workspaceKey = try c.decode(WorkspaceKey.self, forKey: .workspaceKey)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        group = try c.decodeIfPresent(WorkspaceGroupID.self, forKey: .group)
        browserProfileID = try c.decodeIfPresent(BrowserProfileKey.self, forKey: .browserProfileID)
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
    }
}
