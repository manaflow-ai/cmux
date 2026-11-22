import Foundation

public struct WorkspaceMetadataResult: Decodable, Sendable, Equatable {
    public var workspace: WorkspaceHandle
    public var key: WorkspaceKey
    public var color: String?
    public var icon: String?
    public var title: String?
    /// Absent on daemons without `workspace-pin-v1`.
    public var pinned: Bool?
    /// Absent on daemons without `notification-mark-unread-v1`.
    public var markedUnread: Bool?
    public var workspaceRevision: UInt64
    public var changed: Bool
    public var replayed: Bool

    enum CodingKeys: String, CodingKey {
        case workspace, key, color, icon, title, pinned, changed, replayed
        case markedUnread = "marked_unread"
        case workspaceRevision = "workspace_revision"
    }
}

/// Shared color/icon/title (`workspace-metadata-v1`), the sidebar pin
/// (`workspace-pin-v1`), and the manual unread mark
/// (`notification-mark-unread-v1`). Emits `workspace-changed`.
public struct SetWorkspaceMetadataRequest: DaemonRequest {
    public typealias Response = WorkspaceMetadataResult
    public static let command = "set-workspace-metadata"
    public static let requiredCapability: String? = DaemonCapabilities.shared.workspaceMetadata
    public var workspace: WorkspaceRef
    /// Palette token `[a-z][a-z0-9-]{0,31}` or `#RRGGBB[AA]`.
    public var color: FieldUpdate<String>
    /// SF Symbol name.
    public var icon: FieldUpdate<String>
    /// 1-256 characters; overrides `name` for display.
    public var title: FieldUpdate<String>
    /// Nil leaves the pin unchanged; the field has no clear state.
    public var pinned: Bool?
    /// Nil leaves the manual unread mark unchanged.
    public var markedUnread: Bool?
    public var mutation: MutationIdentity?

    public init(workspace: WorkspaceRef, color: FieldUpdate<String> = .unchanged, icon: FieldUpdate<String> = .unchanged,
                title: FieldUpdate<String> = .unchanged, pinned: Bool? = nil, markedUnread: Bool? = nil,
                mutation: MutationIdentity?) {
        self.workspace = workspace
        self.color = color
        self.icon = icon
        self.title = title
        self.pinned = pinned
        self.markedUnread = markedUnread
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey {
        case color, icon, title, pinned
        case markedUnread = "marked_unread"
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(icon, forKey: .icon)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(pinned, forKey: .pinned)
        try c.encodeIfPresent(markedUnread, forKey: .markedUnread)
        try WorkspaceRefFields(ref: workspace).encode(to: encoder)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}
