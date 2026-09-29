import Foundation

// Sidebar groups (`workspace-groups-v1`). Group edits emit `tree-changed`;
// membership changes emit `workspace-moved`.

public struct WorkspaceGroupResult: Decodable, Sendable, Equatable {
    public var group: WorkspaceGroupSnapshot
    public var changed: Bool
}

public struct ListWorkspaceGroupsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var groups: [WorkspaceGroupSnapshot]
    }
    public static let command = "list-workspace-groups"
    public init() {}
}

public struct CreateWorkspaceGroupRequest: DaemonRequest {
    public typealias Response = WorkspaceGroupResult
    public static let command = "create-workspace-group"
    public var name: String
    /// Caller-chosen id makes a retry idempotent; nil lets the daemon generate one.
    public var group: WorkspaceGroupID?
    public var color: String?
    public var collapsed: Bool?
    public var index: Int?

    public init(name: String, group: WorkspaceGroupID? = nil, color: String? = nil, collapsed: Bool? = nil, index: Int? = nil) {
        self.name = name
        self.group = group
        self.color = color
        self.collapsed = collapsed
        self.index = index
    }
}
