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
    /// Absent on daemons without `workspace-keep-awake-v1`.
    public var keepAwake: Bool?
    public var workspaceRevision: UInt64
    public var changed: Bool
    public var replayed: Bool

    enum CodingKeys: String, CodingKey {
        case workspace, key, color, icon, title, pinned, changed, replayed
        case markedUnread = "marked_unread"
        case keepAwake = "keep_awake"
        case workspaceRevision = "workspace_revision"
    }
}
