import Foundation

public struct WorkspaceMetadataResult: Decodable, Sendable, Equatable {
    public var workspace: WorkspaceHandle
    public var key: WorkspaceKey
    public var color: String?
    public var icon: String?
    public var title: String?
    /// Absent on daemons without `workspace-pin-v1`.
    public var pinned: Bool?
    public var workspaceRevision: UInt64
    public var changed: Bool
    public var replayed: Bool

    enum CodingKeys: String, CodingKey {
        case workspace, key, color, icon, title, pinned, changed, replayed
        case workspaceRevision = "workspace_revision"
    }
}

/// Shared color/icon/title (`workspace-metadata-v1`) and the sidebar pin
/// (`workspace-pin-v1`). Emits `workspace-changed`.
public struct SetWorkspaceMetadataRequest: DaemonRequest {
    public typealias Response = WorkspaceMetadataResult
    public static let command = "set-workspace-metadata"
    public var workspace: WorkspaceRef
    /// Palette token `[a-z][a-z0-9-]{0,31}` or `#RRGGBB[AA]`.
    public var color: FieldUpdate<String>
    /// SF Symbol name.
    public var icon: FieldUpdate<String>
    /// 1-256 characters; overrides `name` for display.
    public var title: FieldUpdate<String>
    /// Nil leaves the pin unchanged; the field has no clear state.
    public var pinned: Bool?
    public var mutation: MutationIdentity?

    public init(workspace: WorkspaceRef, color: FieldUpdate<String> = .unchanged, icon: FieldUpdate<String> = .unchanged,
                title: FieldUpdate<String> = .unchanged, pinned: Bool? = nil, mutation: MutationIdentity?) {
        self.workspace = workspace
        self.color = color
        self.icon = icon
        self.title = title
        self.pinned = pinned
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey { case color, icon, title, pinned }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(icon, forKey: .icon)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(pinned, forKey: .pinned)
        try WorkspaceRefFields(ref: workspace).encode(to: encoder)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}
