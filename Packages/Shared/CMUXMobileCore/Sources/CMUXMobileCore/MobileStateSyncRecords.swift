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
    /// The collection's wire name.
    public let rawValue: String

    /// Creates a collection id from its wire name.
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
    /// One surface row within a workspace.
    public struct Surface: Codable, Equatable, Sendable {
        /// Stable surface identifier.
        public let surfaceID: String
        /// Open surface-kind wire string.
        public let kind: String
        /// User-facing surface title.
        public let title: String
        /// Whether the surface currently holds focus on the owning Mac.
        public let isFocused: Bool
        /// Backing file path for file-based surfaces, when reported.
        public let filePath: String?
        /// Bounded checklist/status payload for todo surfaces.
        public let todo: MobileTodoSnapshot?

        /// Creates a surface row from its wire fields.
        public init(
            surfaceID: String,
            kind: String,
            title: String,
            filePath: String?,
            todo: MobileTodoSnapshot? = nil,
            isFocused: Bool = false
        ) {
            self.surfaceID = surfaceID
            self.kind = kind
            self.title = title
            self.isFocused = isFocused
            self.filePath = filePath
            self.todo = todo
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            surfaceID = try container.decode(String.self, forKey: .surfaceID)
            kind = try container.decode(String.self, forKey: .kind)
            title = try container.decode(String.self, forKey: .title)
            isFocused = try container.decodeIfPresent(Bool.self, forKey: .isFocused) ?? false
            filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
            todo = try container.decodeIfPresent(MobileTodoSnapshot.self, forKey: .todo)
        }

        private enum CodingKeys: String, CodingKey {
            case surfaceID = "surface_id"
            case kind
            case title
            case isFocused = "is_focused"
            case filePath = "file_path"
            case todo
        }
    }

    /// One terminal row within a workspace.
    public struct Terminal: Codable, Equatable, Sendable {
        /// Stable terminal identifier.
        public let id: String
        /// User-facing terminal title (custom rename aware).
        public let title: String
        /// The terminal's current working directory, when reported.
        public let currentDirectory: String?
        /// Whether the terminal surface is ready to render.
        public let isReady: Bool
        /// Whether the terminal currently holds focus in its workspace.
        public let isFocused: Bool

        /// Creates a terminal row from its wire fields.
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

    /// Stable workspace identifier.
    public let id: String
    /// Owning Mac window identifier, when reported.
    public let windowID: String?
    /// User-facing workspace title.
    public let title: String
    /// Custom workspace description, when one is set.
    public let customDescription: String?
    /// Whether the Mac's durable description was longer than the mobile value.
    public let customDescriptionIsTruncated: Bool
    /// Custom workspace accent color as `#RRGGBB`, when one is set.
    public let customColorHex: String?
    /// The workspace's presented working directory, when reported.
    public let currentDirectory: String?
    /// Whether the Mac currently has this workspace selected.
    public let isSelected: Bool
    /// Whether the workspace is pinned on the Mac.
    public let isPinned: Bool
    /// The owning group's identifier; nil for ungrouped workspaces.
    public let groupID: String?
    /// One-line plain-text preview of the latest activity, when any.
    public let preview: String?
    /// Unix epoch seconds of the preview's activity, when any.
    public let previewAt: Double?
    /// Unix epoch seconds of the workspace's last activity.
    public let lastActivityAt: Double
    /// Whether the workspace has unread activity on the Mac.
    public let hasUnread: Bool
    /// Position in the Mac's presented cross-window order.
    public let sortIndex: Int
    /// Terminal rows belonging to this workspace, in spatial order.
    public let terminals: [Terminal]
    /// All surface rows belonging to this workspace, in spatial order.
    /// `nil` when decoded from a Mac that predates surface inventory support.
    public let surfaces: [Surface]?
    /// Simulator panes belonging to this workspace, in spatial order.
    public let simulators: [MobileSimulatorPanelDescriptor]

    /// ``MobileSyncRecord`` identity: the workspace id.
    public var syncID: String { id }
    /// ``MobileSyncRecord`` ordering key: the presented list position.
    public var syncSortIndex: Int { sortIndex }

    /// Creates a workspace row from its wire fields.
    public init(
        id: String,
        windowID: String?,
        title: String,
        customDescription: String? = nil,
        customDescriptionIsTruncated: Bool = false,
        customColorHex: String? = nil,
        currentDirectory: String?,
        isSelected: Bool,
        isPinned: Bool,
        groupID: String?,
        preview: String?,
        previewAt: Double?,
        lastActivityAt: Double,
        hasUnread: Bool,
        sortIndex: Int,
        terminals: [Terminal],
        surfaces: [Surface]? = nil,
        simulators: [MobileSimulatorPanelDescriptor] = []
    ) {
        self.id = id
        self.windowID = windowID
        self.title = title
        self.customDescription = customDescription
        self.customDescriptionIsTruncated = customDescriptionIsTruncated
        self.customColorHex = customColorHex
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
        self.surfaces = surfaces
        self.simulators = simulators
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        windowID = try container.decodeIfPresent(String.self, forKey: .windowID)
        title = try container.decode(String.self, forKey: .title)
        customDescription = try container.decodeIfPresent(String.self, forKey: .customDescription)
        customDescriptionIsTruncated = try container.decodeIfPresent(
            Bool.self,
            forKey: .customDescriptionIsTruncated
        ) ?? false
        customColorHex = try container.decodeIfPresent(String.self, forKey: .customColorHex)
        currentDirectory = try container.decodeIfPresent(String.self, forKey: .currentDirectory)
        isSelected = try container.decode(Bool.self, forKey: .isSelected)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        previewAt = try container.decodeIfPresent(Double.self, forKey: .previewAt)
        lastActivityAt = try container.decode(Double.self, forKey: .lastActivityAt)
        hasUnread = try container.decode(Bool.self, forKey: .hasUnread)
        sortIndex = try container.decode(Int.self, forKey: .sortIndex)
        terminals = try container.decode([Terminal].self, forKey: .terminals)
        surfaces = try container.decodeIfPresent([Surface].self, forKey: .surfaces)
        simulators = try container.decodeIfPresent(
            [MobileSimulatorPanelDescriptor].self,
            forKey: .simulators
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case windowID = "window_id"
        case title
        case customDescription = "description"
        case customDescriptionIsTruncated = "description_truncated"
        case customColorHex = "custom_color"
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
        case surfaces
        case simulators
    }
}

/// One workspace group section, mirroring the legacy list payload's group
/// fields. Membership stays derived on the client from each workspace's
/// `group_id` in workspace order, exactly as the legacy list is consumed, so
/// this record intentionally carries no member array to invalidate.
public struct GroupSyncRecord: MobileSyncRecord {
    /// Stable group identifier.
    public let id: String
    /// User-facing group name (section header label).
    public let name: String
    /// Whether the group is collapsed on the Mac.
    public let isCollapsed: Bool
    /// Whether the group is pinned on the Mac.
    public let isPinned: Bool
    /// SF Symbol rendered by the corresponding group row on the Mac.
    public let iconSymbol: String?
    /// The live anchor workspace that owns this group, or `nil` for a
    /// header-only group. Empty groups never publish a placeholder workspace
    /// identifier.
    public let anchorWorkspaceID: String?
    /// Whether this group currently has no live workspace anchor.
    public let isEmpty: Bool
    /// Position in the Mac's presented section order.
    public let sortIndex: Int

    /// ``MobileSyncRecord`` identity: the group id.
    public var syncID: String { id }
    /// ``MobileSyncRecord`` ordering key: the presented section position.
    public var syncSortIndex: Int { sortIndex }

    /// Creates a group row from its wire fields.
    public init(
        id: String,
        name: String,
        isCollapsed: Bool,
        isPinned: Bool,
        iconSymbol: String? = nil,
        anchorWorkspaceID: String?,
        sortIndex: Int,
        isEmpty: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.iconSymbol = iconSymbol
        self.anchorWorkspaceID = anchorWorkspaceID
        self.isEmpty = isEmpty
        self.sortIndex = sortIndex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isCollapsed = try container.decode(Bool.self, forKey: .isCollapsed)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        iconSymbol = try container.decodeIfPresent(String.self, forKey: .iconSymbol)
        anchorWorkspaceID = try container.decodeIfPresent(String.self, forKey: .anchorWorkspaceID)
        isEmpty = try container.decodeIfPresent(Bool.self, forKey: .isEmpty)
            ?? (anchorWorkspaceID == nil)
        sortIndex = try container.decode(Int.self, forKey: .sortIndex)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isCollapsed, forKey: .isCollapsed)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(iconSymbol, forKey: .iconSymbol)
        // Keep the established non-null wire shape for older phones. The
        // explicit `is_empty` bit makes this stable group identity incapable
        // of being mistaken for a live workspace by new clients.
        try container.encode(anchorWorkspaceID ?? id, forKey: .anchorWorkspaceID)
        try container.encode(isEmpty, forKey: .isEmpty)
        try container.encode(sortIndex, forKey: .sortIndex)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isCollapsed = "is_collapsed"
        case isPinned = "is_pinned"
        case iconSymbol = "icon_symbol"
        case anchorWorkspaceID = "anchor_workspace_id"
        case isEmpty = "is_empty"
        case sortIndex = "sort_index"
    }
}
