import Foundation

public struct CreateWorkspaceRequest: DaemonRequest {
    public typealias Response = WorkspaceMutationResult
    public static let command = "create-workspace"
    public var name: String?
    public var key: WorkspaceKey?
    /// The app places the new workspace by `workspaces.newPlacement` against
    /// `current`, the workspace the creating window shows (nil: none, the window
    /// shows a top page). The daemon then places it there too, not against the
    /// session's active workspace, so its first place is the final one. An
    /// older daemon ignores both.
    public var placesBySetting: Bool
    public var current: WorkspaceKey?
    /// The app's `workspaces.newPlacement` value (`top`, `beforeCurrent`, ...): the daemon places by it
    /// rather than its own read of the settings file, so both use one value.
    public var placement: String?
    public var mutation: MutationIdentity?

    public init(name: String? = nil, key: WorkspaceKey? = nil, placesBySetting: Bool = false, current: WorkspaceKey? = nil,
                placement: String? = nil, mutation: MutationIdentity?) {
        self.name = name
        self.key = key
        self.placesBySetting = placesBySetting
        self.current = current
        self.placement = placement
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey {
        case name, key, current, placement
        case placesBySetting = "places_by_setting"
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(key, forKey: .key)
        if placesBySetting { try c.encode(true, forKey: .placesBySetting) }
        try c.encodeIfPresent(current, forKey: .current)
        try c.encodeIfPresent(placement, forKey: .placement)
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
