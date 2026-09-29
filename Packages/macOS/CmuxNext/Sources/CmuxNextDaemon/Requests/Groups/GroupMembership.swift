import Foundation

/// Sets membership (nil ungroups) and optionally the final index among the
/// section's members, in one workspace-registry revision.
public struct MoveWorkspaceToGroupRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var workspace: WorkspaceHandle
        public var key: WorkspaceKey
        public var index: Int
        public var group: WorkspaceGroupID?
        public var workspaceRevision: UInt64
        public var changed: Bool
        public var replayed: Bool
        enum CodingKeys: String, CodingKey {
            case workspace, key, index, group, changed, replayed
            case workspaceRevision = "workspace_revision"
        }
    }
    public static let command = "move-workspace-to-group"
    public var workspace: WorkspaceRef
    public var group: WorkspaceGroupID?
    public var index: Int?
    public var mutation: MutationIdentity?

    public init(workspace: WorkspaceRef, group: WorkspaceGroupID?, index: Int? = nil, mutation: MutationIdentity?) {
        self.workspace = workspace
        self.group = group
        self.index = index
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey { case group, index }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // `group` is required; null means ungrouped.
        if let group { try c.encode(group, forKey: .group) } else { try c.encodeNil(forKey: .group) }
        try c.encodeIfPresent(index, forKey: .index)
        try WorkspaceRefFields(ref: workspace).encode(to: encoder)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}
