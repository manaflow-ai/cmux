import Foundation

public struct CreateWorkspaceRequest: DaemonRequest {
    public typealias Response = WorkspaceMutationResult
    public static let command = "create-workspace"
    public var name: String?
    public var key: WorkspaceKey?
    /// The workspace the creating window shows: the daemon places the new one by
    /// `workspaces.newPlacement` against it, as the app does, not against the
    /// session's active workspace. An older daemon ignores it.
    public var current: WorkspaceKey?
    public var mutation: MutationIdentity?

    public init(name: String? = nil, key: WorkspaceKey? = nil, current: WorkspaceKey? = nil, mutation: MutationIdentity?) {
        self.name = name
        self.key = key
        self.current = current
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey { case name, key, current }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encodeIfPresent(current, forKey: .current)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}

public struct RenameWorkspaceRequest: DaemonRequest {
    public typealias Response = WorkspaceMutationResult
    public static let command = "rename-workspace"
    public var workspace: WorkspaceRef
    public var name: String
    public var source: WorkspaceNameSource?
    public var expectedNameRevision: UInt64?
    public var release: Bool
    public var mutation: MutationIdentity?

    public init(workspace: WorkspaceRef, name: String, source: WorkspaceNameSource? = nil,
                expectedNameRevision: UInt64? = nil, release: Bool = false, mutation: MutationIdentity?) {
        self.workspace = workspace
        self.name = name
        self.source = source
        self.expectedNameRevision = expectedNameRevision
        self.release = release
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey { case name, source, expectedNameRevision = "expected_name_revision", release }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(source, forKey: .source)
        if let expectedNameRevision { try c.encode(String(expectedNameRevision), forKey: .expectedNameRevision) }
        if release { try c.encode(true, forKey: .release) }
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
