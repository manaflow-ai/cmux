import Foundation

/// Records a session in the home registry. A new one is followed by
/// `default` and by `followWith`.
public struct PutSessionRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var session: SessionRecord
        public var created: Bool
    }
    public static let command = "put-session"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public var sessionID: String
    public var machineName: String?
    public var sessionName: String?
    public var transport: JSONValue
    public var capabilities: [String]?
    public var followWith: ProfileID?
    public init(sessionID: String, machineName: String?, sessionName: String?, transport: JSONValue, capabilities: [String]?,
                followWith: ProfileID? = nil) {
        self.sessionID = sessionID
        self.machineName = machineName
        self.sessionName = sessionName
        self.transport = transport
        self.capabilities = capabilities
        self.followWith = followWith
    }
}

/// The one-time copy of a remote daemon's shared groups and order into
/// personal rows; `imported` is false when it already ran.
public struct ImportSessionOrganizationRequest: DaemonRequest {
    public struct Group: Encodable, Sendable, Hashable {
        public var id: WorkspaceGroupID
        public var name: String
        public var color: String?
        public var collapsed: Bool
        public init(id: WorkspaceGroupID, name: String, color: String?, collapsed: Bool) {
            self.id = id
            self.name = name
            self.color = color
            self.collapsed = collapsed
        }
    }
    public struct Workspace: Encodable, Sendable, Hashable {
        public var workspaceKey: WorkspaceKey
        public var group: WorkspaceGroupID?
        public init(workspaceKey: WorkspaceKey, group: WorkspaceGroupID?) {
            self.workspaceKey = workspaceKey
            self.group = group
        }
    }
    public struct Response: Decodable, Sendable, Equatable {
        public var imported: Bool
    }
    public static let command = "import-session-organization"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public var sessionID: String
    public var groups: [Group]
    public var workspaces: [Workspace]
    public init(sessionID: String, groups: [Group], workspaces: [Workspace]) {
        self.sessionID = sessionID
        self.groups = groups
        self.workspaces = workspaces
    }
}

/// Removes a session from the home registry with its personal rows (order,
/// groups, pins). Without `force` the daemon refuses while rooms pin its
/// workspaces.
public struct ForgetSessionRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var changed: Bool
    }
    public static let command = "forget-session"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public var sessionID: String
    public var force: Bool
    public init(sessionID: String, force: Bool) {
        self.sessionID = sessionID
        self.force = force
    }
}
