public import CMUXMobileCore
public import Foundation

/// Typed decoder for the `workspace.list` / `mobile.workspace.list` RPC result.
///
/// The wire shape is snake_case (the Mac side of PR 5079 already emits it); the
/// `CodingKeys` map it onto camelCase Swift properties without changing the wire.
public struct MobileSyncWorkspaceListResponse: Decodable, Sendable {
    /// A workspace entry in the list response.
    public struct Workspace: Decodable, Sendable {
        /// Stable workspace identifier.
        public let id: String
        /// Stable Mac window identifier, when reported.
        public let windowID: String?
        /// User-facing workspace title.
        public let title: String
        /// Custom workspace description, when reported by the Mac.
        public let customDescription: String?
        /// Whether `customDescription` is a bounded projection of a longer Mac value.
        public let customDescriptionIsTruncated: Bool?
        /// Custom workspace accent color as `#RRGGBB`, when reported by the Mac.
        public let customColorHex: String?
        /// The workspace's current working directory, if reported.
        public let currentDirectory: String?
        /// Whether the Mac currently has this workspace selected.
        public let isSelected: Bool
        /// Whether this workspace is pinned, if the Mac reported it. `nil` when
        /// connected to a Mac old enough not to emit `is_pinned`.
        public let isPinned: Bool?
        /// The id of the group this workspace belongs to, if any. `nil` for
        /// ungrouped workspaces and for Macs old enough not to emit groups.
        public let groupID: String?
        /// A one-line, plain-text preview of the most recent activity (the latest
        /// notification body/title), shown under the row like an iMessage preview.
        /// `nil` when the workspace has no activity or the Mac is old enough not to
        /// emit it.
        public let preview: String?
        /// Unix epoch seconds of the preview's activity, for the row's relative
        /// time. `nil` when there is no preview.
        public let previewAt: Double?
        /// Unix epoch seconds of the workspace's last activity. The Mac stamps
        /// this on every workspace (latest notification, falling back to the
        /// workspace's creation/connect time). `nil` on Macs old enough not to
        /// emit it.
        public let lastActivityAt: Double?
        /// Whether the workspace has unread activity on the Mac. `nil` on Macs
        /// old enough not to emit it (the row then shows no unread dot).
        public let hasUnread: Bool?
        /// The exact unread count behind `has_unread` (the number the Mac
        /// sidebar badge shows). `nil` on Macs old enough not to emit it (the
        /// row then falls back to the boolean dot).
        public let unreadCount: Int?
        /// Terminals belonging to this workspace.
        public let terminals: [Terminal]
        /// All workspace surfaces. `nil` when an older Mac omits the field.
        public let surfaces: [Surface]?
        /// Simulator panes belonging to this workspace.
        public let simulators: [MobileSimulatorPanelDescriptor]

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
            case unreadCount = "unread_count"
            case terminals
            case surfaces
            case simulators
        }

        /// Memberwise construction for callers that assemble a row from an
        /// already-synced local source (mobile state sync v2 projects its
        /// record mirror through the same apply path as the wire response).
        public init(
            id: String,
            windowID: String?,
            title: String,
            customDescription: String? = nil,
            customDescriptionIsTruncated: Bool? = nil,
            customColorHex: String? = nil,
            currentDirectory: String?,
            isSelected: Bool,
            isPinned: Bool?,
            groupID: String?,
            preview: String?,
            previewAt: Double?,
            lastActivityAt: Double?,
            hasUnread: Bool?,
            unreadCount: Int? = nil,
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
            self.unreadCount = unreadCount
            self.terminals = terminals
            self.surfaces = surfaces
            self.simulators = simulators
        }

        /// Decodes a workspace row while accepting legacy optional fields.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            windowID = try container.decodeIfPresent(String.self, forKey: .windowID)
            title = try container.decode(String.self, forKey: .title)
            customDescription = try container.decodeIfPresent(String.self, forKey: .customDescription)
            customDescriptionIsTruncated = try container.decodeIfPresent(Bool.self, forKey: .customDescriptionIsTruncated)
            customColorHex = try container.decodeIfPresent(String.self, forKey: .customColorHex)
            currentDirectory = try container.decodeIfPresent(String.self, forKey: .currentDirectory)
            isSelected = try container.decode(Bool.self, forKey: .isSelected)
            isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
            groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
            preview = try container.decodeIfPresent(String.self, forKey: .preview)
            previewAt = try container.decodeIfPresent(Double.self, forKey: .previewAt)
            lastActivityAt = try container.decodeIfPresent(Double.self, forKey: .lastActivityAt)
            hasUnread = try container.decodeIfPresent(Bool.self, forKey: .hasUnread)
            unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount)
            terminals = try container.decode([Terminal].self, forKey: .terminals)
            surfaces = try container.decodeIfPresent([Surface].self, forKey: .surfaces)
            simulators = try container.decodeIfPresent(
                [MobileSimulatorPanelDescriptor].self,
                forKey: .simulators
            ) ?? []
        }
    }

    /// A Mac-rendered surface in workspace spatial order.
    public struct Surface: Decodable, Equatable, Sendable {
        /// Stable Mac-local surface identifier.
        public let surfaceID: String
        /// Open surface-kind wire value.
        public let kind: String
        /// User-facing surface title.
        public let title: String
        /// Whether the surface currently holds focus on the owning Mac.
        public let isFocused: Bool
        /// Backing path for file-oriented surfaces, when present.
        public let filePath: String?
        /// Bounded checklist/status payload for todo surfaces.
        public let todo: MobileTodoSnapshot?

        private enum CodingKeys: String, CodingKey {
            case surfaceID = "surface_id"
            case kind
            case title
            case isFocused = "is_focused"
            case filePath = "file_path"
            case todo
        }

        /// Creates a projected surface DTO.
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
    }

    /// A workspace group section in the list response. Mirrors the iOS-facing
    /// subset the Mac emits (no v2 handle refs or color). Members are
    /// listed in the Mac's spatial (`tabs`) order. Absent on Macs old enough not
    /// to emit groups.
    public struct Group: Decodable, Sendable {
        /// Stable group identifier.
        public let id: String
        /// User-facing group name (shown as the section header label).
        public let name: String
        /// Whether the group is currently collapsed on the Mac.
        public let isCollapsed: Bool
        /// Whether the group is pinned on the Mac.
        public let isPinned: Bool
        /// SF Symbol rendered by the corresponding group row on the Mac.
        public let iconSymbol: String?
        /// The live anchor workspace that owns this group, or `nil` for a
        /// header-only group. Empty groups never publish a placeholder
        /// workspace identifier.
        public let anchorWorkspaceID: String?
        /// Whether this group intentionally has no live workspace anchor.
        public let isEmpty: Bool

        // The Mac also emits `member_workspace_ids`, but membership is derived on
        // the client from each workspace's `group_id` (which preserves spatial
        // order), so the explicit member list is intentionally not decoded here.

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case isCollapsed = "is_collapsed"
            case isPinned = "is_pinned"
            case iconSymbol = "icon_symbol"
            case anchorWorkspaceID = "anchor_workspace_id"
            case isEmpty = "is_empty"
        }

        /// Decodes a group row from both legacy and empty-group payloads.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            isCollapsed = try container.decode(Bool.self, forKey: .isCollapsed)
            isPinned = try container.decode(Bool.self, forKey: .isPinned)
            iconSymbol = try container.decodeIfPresent(String.self, forKey: .iconSymbol)
            anchorWorkspaceID = try container.decodeIfPresent(String.self, forKey: .anchorWorkspaceID)
            let decodedIsEmpty = try container.decodeIfPresent(Bool.self, forKey: .isEmpty) ?? false
            // A null anchor is authoritative even when a legacy or malformed
            // sender reports `is_empty: false`.
            isEmpty = decodedIsEmpty || anchorWorkspaceID == nil
        }

        /// Memberwise construction for locally-synced sources (state sync v2).
        public init(
            id: String,
            name: String,
            isCollapsed: Bool,
            isPinned: Bool,
            iconSymbol: String? = nil,
            anchorWorkspaceID: String?,
            isEmpty: Bool = false
        ) {
            self.id = id
            self.name = name
            self.isCollapsed = isCollapsed
            self.isPinned = isPinned
            self.iconSymbol = iconSymbol
            self.anchorWorkspaceID = anchorWorkspaceID
            self.isEmpty = isEmpty || anchorWorkspaceID == nil
        }
    }

    /// A terminal entry within a workspace.
    public struct Terminal: Decodable, Sendable {
        /// Stable terminal identifier.
        public let id: String
        /// User-facing terminal title.
        public let title: String
        /// The terminal's current working directory, if reported.
        public let currentDirectory: String?
        /// Whether the terminal currently holds focus.
        public let isFocused: Bool
        /// Whether the terminal surface is ready, if reported.
        public let isReady: Bool?

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case currentDirectory = "current_directory"
            case isFocused = "is_focused"
            case isReady = "is_ready"
        }

        /// Memberwise construction for locally-synced sources (state sync v2).
        public init(
            id: String,
            title: String,
            currentDirectory: String?,
            isFocused: Bool,
            isReady: Bool?
        ) {
            self.id = id
            self.title = title
            self.currentDirectory = currentDirectory
            self.isFocused = isFocused
            self.isReady = isReady
        }
    }

    /// The full workspace list.
    public let workspaces: [Workspace]
    /// Group sections, in section order. Empty when the Mac reports no groups or
    /// when an older payload omits the field.
    public let groups: [Group]
    /// Whether the decoded payload carried a `groups` field at all. Older or
    /// partial responses omit the field, and callers use that to preserve the
    /// last authoritative group headers across reconnect churn.
    public let groupsFieldWasPresent: Bool
    /// Identifier of a workspace created by the request, if any.
    public let createdWorkspaceID: String?
    /// Identifier of a terminal created by the request, if any.
    public let createdTerminalID: String?

    private enum CodingKeys: String, CodingKey {
        case workspaces
        case groups
        case createdWorkspaceID = "created_workspace_id"
        case createdTerminalID = "created_terminal_id"
    }

    /// Decodes a workspace-list response, defaulting `groups` to empty so a Mac
    /// old enough not to emit the field still decodes (the grouped UI then stays
    /// flat). `created_workspace_id` / `created_terminal_id` are optional.
    /// - Parameter decoder: The decoder for the RPC result payload.
    /// - Throws: A decoding error if `workspaces` is missing or malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        groupsFieldWasPresent = container.contains(.groups)
        groups = try container.decodeIfPresent([Group].self, forKey: .groups) ?? []
        createdWorkspaceID = try container.decodeIfPresent(String.self, forKey: .createdWorkspaceID)
        createdTerminalID = try container.decodeIfPresent(String.self, forKey: .createdTerminalID)
    }

    /// Decode a workspace-list response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileSyncWorkspaceListResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

// Memberwise construction for callers that assemble a list response from an
// already-synced local source (mobile state sync v2 projects its record mirror
// through the same apply path the decoded wire response uses).
extension MobileSyncWorkspaceListResponse {
    /// Memberwise construction for locally-synced sources (state sync v2
    /// projects its record mirror through the same apply path).
    public init(
        workspaces: [Workspace],
        groups: [Group],
        groupsFieldWasPresent: Bool = true,
        createdWorkspaceID: String?,
        createdTerminalID: String?
    ) {
        self.workspaces = workspaces
        self.groups = groups
        self.groupsFieldWasPresent = groupsFieldWasPresent
        self.createdWorkspaceID = createdWorkspaceID
        self.createdTerminalID = createdTerminalID
    }
}
