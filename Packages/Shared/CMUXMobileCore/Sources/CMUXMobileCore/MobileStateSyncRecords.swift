/// A record participating in mobile state sync v2 (`docs/mobile-state-sync-v2.md`).
///
/// Records are full rows keyed by a stable id: a delta frame carries the whole
/// changed record, never a field patch, so overlapping frames apply
/// idempotently and the client never needs field-merge logic. Equality drives
/// the Mac-side diff: a record that compares equal to the stored one bumps no
/// revision and travels on no wire.
public protocol MobileSyncRecord: Codable, Equatable, Sendable {
    /// Stable identity within the collection (workspace/group UUID string).
    var syncID: String { get }
    /// Position in the Mac's presented order. The client sorts by this, then by
    /// `syncID` for determinism when indices collide mid-delta.
    var syncSortIndex: Int { get }
}

/// Identifies a synced collection on the wire. A raw string wrapper (not an
/// enum) so an older client can skip frames for collections it does not know
/// instead of failing to decode the envelope.
public struct MobileSyncCollectionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The flattened cross-window workspace list.
    public static let workspaces = MobileSyncCollectionID(rawValue: "workspaces")
    /// Workspace group sections.
    public static let groups = MobileSyncCollectionID(rawValue: "groups")
}

/// One workspace row, mirroring the fields of the legacy
/// `mobile.workspace.list` payload (same snake_case wire names) plus an
/// explicit `sort_index` so list order syncs without positional inference.
public struct WorkspaceSyncRecord: MobileSyncRecord {
    /// One terminal row within a workspace.
    public struct Terminal: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let currentDirectory: String?
        public let isReady: Bool
        public let isFocused: Bool

        public init(
            id: String,
            title: String,
            currentDirectory: String?,
            isReady: Bool,
            isFocused: Bool
        ) {
            self.id = id
            self.title = title
            self.currentDirectory = currentDirectory
            self.isReady = isReady
            self.isFocused = isFocused
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case currentDirectory = "current_directory"
            case isReady = "is_ready"
            case isFocused = "is_focused"
        }
    }

    public let id: String
    public let windowID: String?
    public let title: String
    public let currentDirectory: String?
    public let isSelected: Bool
    public let isPinned: Bool
    public let groupID: String?
    public let preview: String?
    public let previewAt: Double?
    public let lastActivityAt: Double
    public let hasUnread: Bool
    public let sortIndex: Int
    public let terminals: [Terminal]

    public var syncID: String { id }
    public var syncSortIndex: Int { sortIndex }

    public init(
        id: String,
        windowID: String?,
        title: String,
        currentDirectory: String?,
        isSelected: Bool,
        isPinned: Bool,
        groupID: String?,
        preview: String?,
        previewAt: Double?,
        lastActivityAt: Double,
        hasUnread: Bool,
        sortIndex: Int,
        terminals: [Terminal]
    ) {
        self.id = id
        self.windowID = windowID
        self.title = title
        self.currentDirectory = currentDirectory
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.groupID = groupID
        self.preview = preview
        self.previewAt = previewAt
        self.lastActivityAt = lastActivityAt
        self.hasUnread = hasUnread
        self.sortIndex = sortIndex
        self.terminals = terminals
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case windowID = "window_id"
        case title
        case currentDirectory = "current_directory"
        case isSelected = "is_selected"
        case isPinned = "is_pinned"
        case groupID = "group_id"
        case preview
        case previewAt = "preview_at"
        case lastActivityAt = "last_activity_at"
        case hasUnread = "has_unread"
        case sortIndex = "sort_index"
        case terminals
    }
}

/// One workspace group section, mirroring the legacy list payload's group
/// fields. Membership stays derived on the client from each workspace's
/// `group_id` in workspace order, exactly as the legacy list is consumed, so
/// this record intentionally carries no member array to invalidate.
public struct GroupSyncRecord: MobileSyncRecord {
    public let id: String
    public let name: String
    public let isCollapsed: Bool
    public let isPinned: Bool
    public let anchorWorkspaceID: String
    public let sortIndex: Int

    public var syncID: String { id }
    public var syncSortIndex: Int { sortIndex }

    public init(
        id: String,
        name: String,
        isCollapsed: Bool,
        isPinned: Bool,
        anchorWorkspaceID: String,
        sortIndex: Int
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.anchorWorkspaceID = anchorWorkspaceID
        self.sortIndex = sortIndex
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isCollapsed = "is_collapsed"
        case isPinned = "is_pinned"
        case anchorWorkspaceID = "anchor_workspace_id"
        case sortIndex = "sort_index"
    }
}
