import Foundation

public struct CreateWorkspaceRequest: DaemonRequest {
    public typealias Response = WorkspaceMutationResult
    public static let command = "create-workspace"
    public var name: String?
    public var key: WorkspaceKey?
    public var mutation: MutationIdentity?
    /// `workspace-first-tab-v1`: the workspace's first tab, made by this request; the reply names it
    /// (``WorkspaceMutationResult/firstTab``). Send it only to a daemon that serves the capability.
    public var firstTab: WorkspaceFirstBrowserTab?
    /// `.user`: `name` is exactly what the caller asked for (`agents chat new --name`, `agent open --name`), so the
    /// daemon pins it like a rename and no automatic name or chat title replaces it (#56422). Nil: a starting name
    /// (Cmd-N's `workspace-N`, a moved tab's name), the automatic namer's. A daemon without it ignores the field.
    public var nameSource: WorkspaceNameSource?

    public init(name: String? = nil, key: WorkspaceKey? = nil, firstTab: WorkspaceFirstBrowserTab? = nil, nameSource: WorkspaceNameSource? = nil,
                mutation: MutationIdentity?) {
        self.name = name
        self.key = key
        self.firstTab = firstTab
        self.nameSource = nameSource
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey {
        case name, key
        case firstTab = "first_tab"
        case nameSource = "name_source"
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encodeIfPresent(firstTab, forKey: .firstTab)
        if name != nil { try c.encodeIfPresent(nameSource, forKey: .nameSource) }
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
