import Foundation

public struct UpdateWorkspaceGroupRequest: DaemonRequest {
    public typealias Response = WorkspaceGroupResult
    public static let command = "update-workspace-group"
    public var group: WorkspaceGroupID
    public var name: String?
    public var color: FieldUpdate<String>
    public var collapsed: Bool?

    public init(group: WorkspaceGroupID, name: String? = nil, color: FieldUpdate<String> = .unchanged, collapsed: Bool? = nil) {
        self.group = group
        self.name = name
        self.color = color
        self.collapsed = collapsed
    }

    enum CodingKeys: String, CodingKey { case group, name, color, collapsed }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(group, forKey: .group)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encodeIfPresent(collapsed, forKey: .collapsed)
    }
}

/// Deletes a group; its workspaces stay in place, ungrouped.
public struct DeleteWorkspaceGroupRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var group: WorkspaceGroupID
        public var ungroupedKeys: [WorkspaceKey]
        enum CodingKeys: String, CodingKey {
            case group
            case ungroupedKeys = "ungrouped_keys"
        }
    }
    public static let command = "delete-workspace-group"
    public var group: WorkspaceGroupID
    public init(group: WorkspaceGroupID) { self.group = group }
}

public struct MoveWorkspaceGroupRequest: DaemonRequest {
    public typealias Response = WorkspaceGroupResult
    public static let command = "move-workspace-group"
    public var group: WorkspaceGroupID
    public var index: Int
    public init(group: WorkspaceGroupID, index: Int) {
        self.group = group
        self.index = index
    }
}
