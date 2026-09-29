import Foundation

public struct CreateWorkspaceRequest: DaemonRequest {
    public typealias Response = WorkspaceMutationResult
    public static let command = "create-workspace"
    public var name: String?
    public var key: WorkspaceKey?
    public var mutation: MutationIdentity?

    public init(name: String? = nil, key: WorkspaceKey? = nil, mutation: MutationIdentity?) {
        self.name = name
        self.key = key
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey { case name, key }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(key, forKey: .key)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}

public struct RenameWorkspaceRequest: DaemonRequest {
    public typealias Response = WorkspaceMutationResult
    public static let command = "rename-workspace"
    public var workspace: WorkspaceRef
    public var name: String
    public var mutation: MutationIdentity?

    public init(workspace: WorkspaceRef, name: String, mutation: MutationIdentity?) {
        self.workspace = workspace
        self.name = name
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey { case name }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try WorkspaceRefFields(ref: workspace).encode(to: encoder)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}

public struct MoveWorkspaceRequest: DaemonRequest {
    public typealias Response = WorkspaceMutationResult
    public static let command = "move-workspace"
    public var workspace: WorkspaceRef
    public var index: Int
    public var mutation: MutationIdentity?

    public init(workspace: WorkspaceRef, index: Int, mutation: MutationIdentity?) {
        self.workspace = workspace
        self.index = index
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey { case index }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try WorkspaceRefFields(ref: workspace).encode(to: encoder)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}
